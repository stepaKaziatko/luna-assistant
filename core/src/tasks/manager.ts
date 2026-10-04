import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { createTaskWorkdir } from "../context/workdir.ts";
import type { Executor, ExecutorEvent } from "../executors/executor.ts";
import { buildPrompt, FORMAT_RULES, type HistoryTurn } from "../prompt/build.ts";
import type { ExecutorId, TaskInfo, TaskSubmitParams } from "../rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, type StoredTask, type TaskHistory } from "./history.ts";

export type TaskEventName = "task.started" | "task.progress" | "task.done" | "task.failed" | "task.cancelled";

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

interface Entry {
  info: TaskInfo;
  abort: AbortController;
  /** Рабочая директория исполнителя; в протокол не выходит. У уточнения известна заранее. */
  workdir?: string;
  /** Сессия исполнителя, которую продолжает уточнение. */
  resume?: { sessionId: string };
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

    if (params.followUpOf !== undefined) {
      const point = this.followUpPoint(params.followUpOf);
      // Уточнение — в той же сессии и той же директории: сессии Claude Code привязаны к пути.
      info.threadId = point.task.threadId;
      info.executor = point.task.executor;
      entry.workdir = point.workdir ?? join(this.options.tasksDir, point.task.threadId);
      entry.resume = { sessionId: point.sessionId };
    } else if (params.context) {
      info.context = params.context;
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
      this.save(entry);
      entry.abort.abort();
    }
  }

  /** Активные задачи и последние завершённые — из этой сессии и из истории, новые первыми. */
  list(): TaskInfo[] {
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
      this.save(entry);
      // У уточнения контекста нет: промпт — только <task>, прежний разговор уже в сессии.
      let outcome = await this.follow(entry, executor.run({
        prompt: buildPrompt(info.prompt, info.context),
        formatRules: FORMAT_RULES,
        cwd,
        signal: abort.signal,
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
        outcome = await this.follow(entry, executor.run({ prompt: resend, formatRules: FORMAT_RULES, cwd, signal: abort.signal }));
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
        case "progress":
          // Прогресс на диск не пишется: он устаревает раньше, чем его прочтут.
          info.progress = event.text;
          this.emit("task.progress", info);
          break;
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
    this.save(entry);
    this.emit(event, entry.info);
  }

  /** Сбой записи не мешает задаче: она выполняется и видна в этой сессии. */
  private save(entry: Entry): void {
    if (!this.options.history) return;
    try {
      const { progress: _, ...snapshot } = entry.info;
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
