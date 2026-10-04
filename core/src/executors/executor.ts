import type { ExecutorId, ExecutorStatus, TaskError } from "../rpc/protocol.gen.ts";

/** Нормализованные события исполнителя; ядро превращает их в task.* для shell. */
export type ExecutorEvent =
  | { type: "session"; sessionId: string }
  | { type: "progress"; text: string }
  | { type: "done"; result: string }
  | { type: "failed"; error: TaskError };

export interface ExecutorRequest {
  /** Тело запроса: <context> + <task>. */
  prompt: string;
  /** Требования к формату ответа; исполнитель сам решает, как их передать модели. */
  formatRules: string;
  cwd: string;
  signal: AbortSignal;
}

export interface Executor {
  readonly id: ExecutorId;
  status(): Promise<ExecutorStatus>;
  /** Поток завершается после done/failed либо молча — при отмене через signal. */
  run(request: ExecutorRequest): AsyncIterable<ExecutorEvent>;
}
