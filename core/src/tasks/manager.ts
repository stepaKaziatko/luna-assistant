import { randomUUID } from "node:crypto";
import { createTaskWorkdir } from "../context/workdir.ts";
import type { Executor } from "../executors/executor.ts";
import { buildPrompt, FORMAT_RULES } from "../prompt/build.ts";
import type { ExecutorId, TaskInfo, TaskSubmitParams } from "../rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, type TaskHistory } from "./history.ts";

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

interface Entry {
  info: TaskInfo;
  abort: AbortController;
  /** Рабочая директория исполнителя; в протокол не выходит. */
  workdir?: string;
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

  submit(params: TaskSubmitParams): TaskInfo {
    const info: TaskInfo = {
      id: randomUUID(),
      prompt: params.prompt,
      status: "queued",
      executor: params.executor ?? this.options.defaultExecutor,
      createdAt: Date.now(),
    };
    if (params.context) info.context = params.context;

    const entry: Entry = { info, abort: new AbortController() };
    this.entries.set(info.id, entry);
    this.queue.push(entry);
    this.save(entry);
    const snapshot = { ...info };
    // Запуск — на следующем тике, чтобы ответ на task.submit ушёл раньше событий задачи.
    setImmediate(() => this.pump());
    return snapshot;
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

      const cwd = await createTaskWorkdir(this.options.tasksDir, info.id);
      entry.workdir = cwd;
      this.save(entry);
      const events = executor.run({
        prompt: buildPrompt(info.prompt, info.context),
        formatRules: FORMAT_RULES,
        cwd,
        signal: abort.signal,
      });

      for await (const event of events) {
        if (isFinal(info)) return;
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
            this.finish(entry, "task.done", { status: "done", result: event.result });
            return;
          case "failed":
            this.finish(entry, "task.failed", { status: "failed", error: event.error });
            return;
        }
      }
      if (!isFinal(info)) throw new Error("Исполнитель завершился без результата");
    } catch (error) {
      if (isFinal(info)) return;
      const message = error instanceof Error ? error.message : String(error);
      this.finish(entry, "task.failed", { status: "failed", error: { kind: "unknown", message } });
    }
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

function isFinal(info: TaskInfo): boolean {
  return info.status === "done" || info.status === "failed" || info.status === "cancelled";
}
