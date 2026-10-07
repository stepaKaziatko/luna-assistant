import { randomUUID } from "node:crypto";
import { mkdir, rm } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import { createTaskWorkdir } from "../context/workdir.ts";
import type { Executor, ExecutorEvent } from "../executors/executor.ts";
import { buildPrompt, FORMAT_RULES, type HistoryTurn } from "../prompt/build.ts";
import type { ApprovalRequest, ExecutorId, TaskInfo, TaskSubmitParams } from "../rpc/protocol.gen.ts";
import { foldCase, INTERRUPTED_MESSAGE, type StoredTask, type TaskHistory } from "./history.ts";
import { isValidModel } from "./model.ts";

export type TaskEventName = "task.started" | "task.progress" | "task.needs_approval" | "task.done" | "task.failed" | "task.cancelled";

export interface TaskManagerOptions {
  executors: Executor[];
  defaultExecutor: ExecutorId;
  /** Корень рабочих директорий: <tasksDir>/<task_id>/ */
  tasksDir: string;
  maxConcurrent?: number;
  /** История на диске; без неё задачи живут только в памяти. */
  history?: TaskHistory;
  emit: (event: TaskEventName, task: TaskInfo) => void;
}

/** Сколько задач отдаёт `list()`: активные — всегда, остальное — последние завершённые. */
export const LIST_LIMIT = 200;

/** Прогресс уточнения, сессию которого исполнитель потерял: переписка уходит ему заново. */
export const RESEND_PROGRESS = "разговор не сохранился, отправляю переписку заново…";

/** Уточнение нельзя принять; `main.ts` отвечает на него `InvalidParams`. */
export class FollowUpError extends Error {}

/** Диалог с выполняющейся задачей удалить нельзя; `main.ts` отвечает `InvalidParams`. */
export class ActiveDialogError extends Error {}

/** Ответ на подтверждение принять нельзя: задачи нет, она не ждёт или запрос устарел; `main.ts` отвечает `InvalidParams`. */
export class ApprovalError extends Error {}

interface Entry {
  info: TaskInfo;
  abort: AbortController;
  /** Рабочая директория исполнителя; в протокол не выходит. У уточнения известна заранее. */
  workdir?: string;
  /** Сессия исполнителя, которую продолжает уточнение. */
  resume?: { sessionId: string };
  /**
   * Модель, выбранная при отправке (или унаследованная уточнением), — в терминах исполнителя. В протокол не выходит: `info.model`
   * заменяется точной моделью исполнителя, а при повторной отправке переписки он должен
   * получить именно выбор.
   */
  model?: string;
  /** Пауза исполнителя, которая ждёт ответа: id запроса из `info.approval` и способ ответить. */
  pause?: { approvalId: string; respond: (allow: boolean) => void };
}

export class TaskManager {
  private readonly entries = new Map<string, Entry>();
  private readonly queue: Entry[] = [];
  private readonly executors: Map<ExecutorId, Executor>;
  private readonly options: TaskManagerOptions;
  private readonly maxConcurrent: number;
  private running = 0;

  constructor(options: TaskManagerOptions) {
    this.options = options;
    this.executors = new Map(options.executors.map((executor) => [executor.id, executor]));
    this.maxConcurrent = options.maxConcurrent ?? 3;
  }

  /** Бросает `FollowUpError`, если `followUpOf` указывает не на точку продолжения диалога. */
  submit(params: TaskSubmitParams): TaskInfo {
    const id = randomUUID();
    const info: TaskInfo = {
      id,
      threadId: id,
      prompt: params.prompt,
      status: "queued",
      executor: params.executor ?? this.options.defaultExecutor,
      createdAt: Date.now(),
    };
    const entry: Entry = { info, abort: new AbortController() };

    let inheritedModel: string | undefined;
    if (params.followUpOf !== undefined) {
      const point = this.followUpPoint(params.followUpOf);
      if (isValidModel(point.task.model)) inheritedModel = point.task.model;
      // Уточнение — в той же сессии и той же директории: сессии Claude Code привязаны к пути.
      info.threadId = point.task.threadId;
      info.executor = point.task.executor;
      entry.workdir = point.workdir ?? join(this.options.tasksDir, point.task.threadId);
      entry.resume = { sessionId: point.sessionId };
    } else if (params.context) {
      info.context = params.context;
    }
    // Уточнение без `model` остаётся на модели точки продолжения. Она пришла из вывода CLI или
    // истории и попадёт в argv, поэтому проходит ту же проверку шаблона, что и значение из протокола;
    // не прошла — как «модели нет». `entry.model` в истории не хранится: источник — только `TaskInfo`.
    const model = params.model ?? inheritedModel;
    if (model !== undefined) {
      info.model = model;
      entry.model = model;
    }

    this.entries.set(info.id, entry);
    this.queue.push(entry);
    this.save(entry);
    const snapshot = { ...info };
    // Запуск — на следующем тике, чтобы ответ на task.submit ушёл раньше событий задачи.
    setImmediate(() => this.pump());
    return snapshot;
  }

  /**
   * Точка продолжения диалога — его последняя задача `done` с `sessionId`. После неё могут идти
   * только неудачные или отменённые уточнения, кроме потерянной сессии: `session_not_found`
   * остаётся у задачи, только когда переписку отправить заново было нечем (в диалоге нет ни
   * одного сохранённого ответа), — такой диалог не продолжается. Пока в диалоге есть активная
   * задача, уточнение не принимается.
   */
  private followUpPoint(taskId: string): { task: TaskInfo; sessionId: string; workdir?: string } {
    const target = this.entries.get(taskId) ?? this.storedTask(taskId);
    if (!target) throw new FollowUpError(`task not found: ${taskId}`);
    if (target.info.status !== "done") throw new FollowUpError(`task is ${target.info.status}, not done`);
    const sessionId = target.info.sessionId;
    if (!sessionId) throw new FollowUpError("task has no executor session");

    const thread = this.thread(target.info.threadId);
    if (thread.some(isActive)) throw new FollowUpError("dialog has an active task");
    const later = thread.slice(thread.findIndex((task) => task.id === taskId) + 1);
    if (later.some((task) => task.status === "done")) throw new FollowUpError("task is not the last answer of its dialog");
    if (later.some((task) => task.error?.kind === "session_not_found")) {
      throw new FollowUpError("executor session of this dialog is lost");
    }
    return { task: target.info, sessionId, ...(target.workdir ? { workdir: target.workdir } : {}) };
  }

  /** Задачи диалога в порядке создания: с диска и из памяти, память свежее. */
  private thread(threadId: string): TaskInfo[] {
    const tasks = new Map<string, TaskInfo>();
    for (const { task } of this.storedThread(threadId)) tasks.set(task.id, task);
    for (const { info } of this.entries.values()) if (info.threadId === threadId) tasks.set(info.id, info);
    // Сортировка устойчива: при равном времени остаётся порядок записи.
    return [...tasks.values()].sort((a, b) => a.createdAt - b.createdAt);
  }

  /** Возвращает false, если задачи нет или она уже завершена. */
  cancel(taskId: string): boolean {
    const entry = this.entries.get(taskId);
    if (!entry || isFinal(entry.info)) return false;

    const queuedAt = this.queue.indexOf(entry);
    if (queuedAt !== -1) this.queue.splice(queuedAt, 1);
    this.finish(entry, "task.cancelled", { status: "cancelled" });
    entry.abort.abort();
    return true;
  }

  /**
   * Выход из Luna: исполнители останавливаются, а незавершённые задачи записываются
   * в историю ошибкой — после перезапуска видно, что они прерваны. Событий нет: оболочка
   * уже завершается.
   */
  shutdown(): void {
    this.queue.length = 0;
    for (const entry of this.entries.values()) {
      if (isFinal(entry.info)) continue;
      Object.assign(entry.info, {
        status: "failed",
        error: { kind: "unknown", message: INTERRUPTED_MESSAGE },
        finishedAt: Date.now(),
      } satisfies Partial<TaskInfo>);
      delete entry.info.progress;
      delete entry.info.approval;
      delete entry.pause;
      this.save(entry);
      entry.abort.abort();
    }
  }

  /**
   * Ответ человека на паузу исполнителя. Бросает `ApprovalError`, если задача неизвестна или уже
   * завершена, не ждёт ответа или `approvalId` не совпадает с текущим запросом (устарел). После ответа
   * `approval` снимается и уходит `task.progress`: задача идёт дальше.
   */
  approve(taskId: string, approvalId: string, allow: boolean): void {
    const entry = this.entries.get(taskId);
    if (!entry || isFinal(entry.info)) throw new ApprovalError(`task not found or finished: ${taskId}`);
    const pause = entry.pause;
    if (!pause) throw new ApprovalError("task is not waiting for approval");
    if (pause.approvalId !== approvalId) throw new ApprovalError(`approval is outdated: ${approvalId}`);
    delete entry.pause;
    delete entry.info.approval;
    pause.respond(allow);
    this.emit("task.progress", entry.info);
  }

  /**
   * Без запроса — активные задачи и последние завершённые, из этой сессии и из истории, новые
   * первыми. С запросом — не больше `LIST_LIMIT` задач, у которых запрос или ответ содержит его
   * без учёта регистра, вместе с остальными задачами их диалогов.
   */
  list(params: { query?: string } = {}): TaskInfo[] {
    const query = params.query?.trim() ?? "";
    return query === "" ? this.latest() : this.search(query);
  }

  private search(query: string): TaskInfo[] {
    const needle = foldCase(query);
    const matches = (task: TaskInfo) => foldCase(task.prompt).includes(needle) || foldCase(task.result ?? "").includes(needle);
    const found = new Map<string, TaskInfo>();
    for (const { info } of this.entries.values()) if (matches(info)) found.set(info.id, info);
    // Задачи из памяти свежее записей: их совпадение уже решено выше.
    const stored = this.readHistory((history) => history.search(query, LIST_LIMIT + this.entries.size)) ?? [];
    for (const { task } of stored) if (!this.entries.has(task.id)) found.set(task.id, task);

    const newestFirst = (a: TaskInfo, b: TaskInfo) => b.createdAt - a.createdAt;
    const threadIds = new Set([...found.values()].sort(newestFirst).slice(0, LIST_LIMIT).map((task) => task.threadId));
    // Диалог — одной строкой и целиком: к совпавшим задачам добавляются остальные задачи их диалогов.
    const result: TaskInfo[] = [];
    for (const threadId of threadIds) for (const task of this.thread(threadId)) result.push({ ...task });
    return result.sort(newestFirst);
  }

  /**
   * Удаляет диалог задачи целиком: записи в истории, задачи в памяти и рабочие директории.
   * Возвращает id удалённых задач; неизвестная задача — пустой список. Бросает
   * `ActiveDialogError`, если в диалоге есть задача в очереди или в работе, и ошибку истории,
   * если удалить записи не удалось, — тогда ничего не удалено.
   */
  async delete(taskId: string): Promise<string[]> {
    const target = this.entries.get(taskId)?.info ?? this.storedTask(taskId)?.info;
    if (!target) return [];
    if (this.thread(target.threadId).some(isActive)) throw new ActiveDialogError("dialog has an active task");
    return this.remove((history) => history.deleteThreads([target.threadId]), (threadId) => threadId === target.threadId);
  }

  /** Удаляет все диалоги, в которых нет задачи в очереди или в работе. Возвращает id удалённых задач. */
  async clear(): Promise<string[]> {
    const active = new Set([...this.entries.values()].filter(({ info }) => isActive(info)).map(({ info }) => info.threadId));
    return this.remove((history) => history.deleteThreadsExcept([...active]), (threadId) => !active.has(threadId));
  }

  /**
   * Сначала история — её сбой прерывает удаление целиком, затем память, затем директории.
   * Директория удаляется, только если лежит внутри `tasksDir`; сбой — в stderr, ответ успешный.
   */
  private async remove(fromHistory: (history: TaskHistory) => StoredTask[], inThread: (threadId: string) => boolean): Promise<string[]> {
    const stored = this.options.history ? fromHistory(this.options.history) : [];
    const deleted = new Map<string, string | undefined>(stored.map(({ task, workdir }) => [task.id, workdir]));
    const threads = new Set(stored.map(({ task }) => task.threadId));
    for (const [id, entry] of this.entries) {
      if (!inThread(entry.info.threadId)) continue;
      this.entries.delete(id);
      deleted.set(id, entry.workdir ?? deleted.get(id));
      threads.add(entry.info.threadId);
    }

    // У задач старой схемы директория не записана: кандидаты — по id задачи и по id диалога.
    const dirs = new Set<string>();
    for (const [id, workdir] of deleted) {
      if (workdir) dirs.add(workdir);
      dirs.add(join(this.options.tasksDir, id));
    }
    for (const threadId of threads) dirs.add(join(this.options.tasksDir, threadId));
    const root = resolve(this.options.tasksDir) + sep;
    await Promise.all(
      [...dirs].map(async (dir) => {
        if (!resolve(dir).startsWith(root)) return;
        try {
          await rm(dir, { recursive: true, force: true });
        } catch (error) {
          log(`рабочая директория ${dir} не удалена: ${describe(error)}`);
        }
      }),
    );
    return [...deleted.keys()];
  }

  /** Активные задачи и последние завершённые — из этой сессии и из истории, новые первыми. */
  private latest(): TaskInfo[] {
    const active: TaskInfo[] = [];
    const finished = new Map<string, TaskInfo>();
    // От поздних к ранним: при равном createdAt порядок тот же, что у истории.
    for (const { info } of [...this.entries.values()].reverse()) {
      if (isFinal(info)) finished.set(info.id, { ...info });
      else active.push({ ...info });
    }
    for (const { task } of this.recentHistory()) {
      // Память свежее диска: там же задачи, запись которых не удалась.
      if (!this.entries.has(task.id)) finished.set(task.id, task);
    }
    const newestFirst = (a: TaskInfo, b: TaskInfo) => b.createdAt - a.createdAt;
    const kept = [...finished.values()].sort(newestFirst).slice(0, Math.max(0, LIST_LIMIT - active.length));
    return [...active, ...kept].sort(newestFirst);
  }

  private pump(): void {
    while (this.running < this.maxConcurrent) {
      const entry = this.queue.shift();
      if (!entry) return;
      this.running += 1;
      void this.run(entry).finally(() => {
        this.running -= 1;
        this.pump();
      });
    }
  }

  private async run(entry: Entry): Promise<void> {
    const { info, abort } = entry;
    try {
      const executor = this.executors.get(info.executor);
      if (!executor) throw new Error(`Неизвестный исполнитель: ${info.executor}`);

      info.status = "running";
      this.emit("task.started", info);

      // Директорию уточнения могла удалить очистка — создаётся пустая по тому же пути.
      const cwd = entry.workdir
        ? (await mkdir(entry.workdir, { recursive: true }), entry.workdir)
        : await createTaskWorkdir(this.options.tasksDir, info.id);
      entry.workdir = cwd;
      // Отменённая за это время задача исполнителя не запускает: её диалог могли уже удалить.
      if (isFinal(info)) return;
      this.save(entry);
      // У уточнения контекста нет: промпт — только <task>, прежний разговор уже в сессии.
      let outcome = await this.follow(entry, executor.run({
        prompt: buildPrompt(info.prompt, info.context),
        formatRules: FORMAT_RULES,
        cwd,
        signal: abort.signal,
        ...(entry.model !== undefined ? { model: entry.model } : {}),
        ...(entry.resume ? { resume: entry.resume } : {}),
      }));

      // Исполнитель потерял сессию уточнения — один раз отправляем ему переписку заново,
      // новой сессией в той же директории. Отменённая за это время задача не перезапускается.
      const resend = entry.resume && outcome?.type === "failed" && outcome.error.kind === "session_not_found" && !isFinal(info)
        ? this.resendPrompt(info)
        : undefined;
      if (resend !== undefined) {
        // Потерянный id пришёл в первом потоке — у задачи его оставлять нельзя.
        delete info.sessionId;
        this.save(entry);
        info.progress = RESEND_PROGRESS;
        this.emit("task.progress", info);
        outcome = await this.follow(entry, executor.run({
          prompt: resend,
          formatRules: FORMAT_RULES,
          cwd,
          signal: abort.signal,
          ...(entry.model !== undefined ? { model: entry.model } : {}),
        }));
      }

      if (isFinal(info)) return;
      if (outcome?.type === "done") this.finish(entry, "task.done", { status: "done", result: outcome.result });
      else if (outcome?.type === "failed") this.finish(entry, "task.failed", { status: "failed", error: outcome.error });
      else throw new Error("Исполнитель завершился без результата");
    } catch (error) {
      if (isFinal(info)) return;
      const message = error instanceof Error ? error.message : String(error);
      this.finish(entry, "task.failed", { status: "failed", error: { kind: "unknown", message } });
    }
  }

  /**
   * Ведёт задачу по потоку одного запуска исполнителя: сессия и прогресс — сразу, итог
   * (`done`/`failed`) возвращается вызывающему. Undefined — поток кончился без итога
   * или задача уже завершена (отменена). Выход из цикла закрывает поток и процесс исполнителя.
   */
  private async follow(
    entry: Entry,
    events: AsyncIterable<ExecutorEvent>,
  ): Promise<Extract<ExecutorEvent, { type: "done" | "failed" }> | undefined> {
    const { info } = entry;
    for await (const event of events) {
      if (isFinal(info)) return undefined;
      switch (event.type) {
        case "session":
          info.sessionId = event.sessionId;
          this.save(entry);
          break;
        case "model":
          // Отдельного task.progress нет: модель уходит в ближайшем progress/done/failed.
          info.model = event.model;
          this.save(entry);
          break;
        case "progress":
          // Прогресс на диск не пишется: он устаревает раньше, чем его прочтут.
          info.progress = event.text;
          this.emit("task.progress", info);
          break;
        case "pause": {
          // Новый запрос при висящем прежнем заменяет его: прежний закрывается отказом, чтобы исполнитель
          // не ждал ответа, которого человек уже не увидит. Очередь запросов — отдельная задача.
          entry.pause?.respond(false);
          const approval: ApprovalRequest = {
            id: randomUUID(),
            tool: event.request.tool,
            kind: event.request.kind,
            summary: event.request.summary,
            createdAt: Date.now(),
          };
          if (event.request.target !== undefined) approval.target = event.request.target;
          if (event.request.detail !== undefined) approval.detail = event.request.detail;
          entry.pause = { approvalId: approval.id, respond: event.respond };
          info.approval = approval;
          // Статус остаётся running: ждёт не Luna, а исполнитель — ответа человека.
          this.emit("task.needs_approval", info);
          break;
        }
        case "done":
        case "failed":
          return event;
      }
    }
    return undefined;
  }

  /**
   * Промпт повторной отправки: контекст первой задачи диалога, прежние вопросы и ответы
   * (только `done` с непустым ответом) и само уточнение. Undefined — отправлять нечего:
   * в диалоге нет ни одного сохранённого ответа.
   */
  private resendPrompt(info: TaskInfo): string | undefined {
    const earlier = this.thread(info.threadId).filter((task) => task.id !== info.id && task.createdAt <= info.createdAt);
    const history: HistoryTurn[] = earlier
      .filter((task) => task.status === "done" && task.result?.trim())
      .map((task) => ({ question: task.prompt, answer: task.result ?? "" }));
    if (history.length === 0) return undefined;
    // Первая задача могла уйти из истории (предел, удаление) — тогда без <context>.
    const first = earlier.find((task) => task.id === info.threadId);
    return buildPrompt(info.prompt, first?.context, history);
  }

  private finish(entry: Entry, event: TaskEventName, patch: Partial<TaskInfo>): void {
    Object.assign(entry.info, patch, { finishedAt: Date.now() });
    delete entry.info.progress;
    // Ответа мосту не нужно: вместе с задачей останавливается и исполнитель.
    delete entry.info.approval;
    delete entry.pause;
    this.save(entry);
    this.emit(event, entry.info);
  }

  /** Сбой записи не мешает задаче: она выполняется и видна в этой сессии. */
  private save(entry: Entry): void {
    // Удалённая задача не возвращается в историю поздней записью из run() или follow().
    if (!this.options.history || this.entries.get(entry.info.id) !== entry) return;
    try {
      // Ожидание ответа, как и прогресс, живёт только в этой сессии: после перезапуска его не продолжить.
      const { progress: _progress, approval: _approval, ...snapshot } = entry.info;
      this.options.history.save(snapshot, entry.workdir);
    } catch (error) {
      log(`история: задача ${entry.info.id} не записана: ${describe(error)}`);
    }
  }

  /** Сбой чтения истории — как будто задачи там нет: уточнение отклонится, ядро работает. */
  private storedTask(id: string): { info: TaskInfo; workdir?: string } | undefined {
    const stored = this.readHistory((history) => history.get(id));
    return stored ? { info: stored.task, ...(stored.workdir ? { workdir: stored.workdir } : {}) } : undefined;
  }

  private storedThread(threadId: string): StoredTask[] {
    return this.readHistory((history) => history.thread(threadId)) ?? [];
  }

  private readHistory<T>(read: (history: TaskHistory) => T): T | undefined {
    if (!this.options.history) return undefined;
    try {
      return read(this.options.history);
    } catch (error) {
      log(`история не читается: ${describe(error)}`);
      return undefined;
    }
  }

  private recentHistory() {
    if (!this.options.history) return [];
    try {
      return this.options.history.recent(LIST_LIMIT);
    } catch (error) {
      log(`история не читается: ${describe(error)}`);
      return [];
    }
  }

  private emit(event: TaskEventName, info: TaskInfo): void {
    this.options.emit(event, { ...info });
  }
}

// stdout занят протоколом — диагностика только в stderr.
function log(message: string): void {
  process.stderr.write(`[core] ${message}\n`);
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isActive(info: TaskInfo): boolean {
  return info.status === "queued" || info.status === "running";
}

function isFinal(info: TaskInfo): boolean {
  return info.status === "done" || info.status === "failed" || info.status === "cancelled";
}
