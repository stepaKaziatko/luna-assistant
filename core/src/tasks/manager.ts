import { randomUUID } from "node:crypto";
import { createTaskWorkdir } from "../context/workdir.ts";
import type { Executor } from "../executors/executor.ts";
import { buildPrompt, FORMAT_RULES } from "../prompt/build.ts";
import type { ExecutorId, TaskInfo, TaskSubmitParams } from "../rpc/protocol.gen.ts";

export type TaskEventName = "task.started" | "task.progress" | "task.done" | "task.failed" | "task.cancelled";

export interface TaskManagerOptions {
  executors: Executor[];
  defaultExecutor: ExecutorId;
  /** Корень рабочих директорий: <tasksDir>/<task_id>/ */
  tasksDir: string;
  maxConcurrent?: number;
  emit: (event: TaskEventName, task: TaskInfo) => void;
}

interface Entry {
  info: TaskInfo;
  abort: AbortController;
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

  cancelAll(): void {
    for (const id of [...this.entries.keys()]) this.cancel(id);
  }

  list(): TaskInfo[] {
    return [...this.entries.values()].map((entry) => ({ ...entry.info }));
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
            break;
          case "progress":
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
    this.emit(event, entry.info);
  }

  private emit(event: TaskEventName, info: TaskInfo): void {
    this.options.emit(event, { ...info });
  }
}

function isFinal(info: TaskInfo): boolean {
  return info.status === "done" || info.status === "failed" || info.status === "cancelled";
}
