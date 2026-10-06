import type { ExecutorId, ExecutorStatus, TaskError } from "../rpc/protocol.gen.ts";

/** Нормализованные события исполнителя; ядро превращает их в task.* для shell. */
export type ExecutorEvent =
  | { type: "session"; sessionId: string }
  /** Точная модель, на которой работает исполнитель; приходит, когда он её сообщил. */
  | { type: "model"; model: string }
  | { type: "progress"; text: string }
  | { type: "done"; result: string }
  | { type: "failed"; error: TaskError };

export interface ExecutorRequest {
  /** Тело запроса: <context> + <task>; у уточнения — только <task>; при повторной отправке переписки — <context> первой задачи, <history> и <task>. */
  prompt: string;
  /** Требования к формату ответа; исполнитель сам решает, как их передать модели. */
  formatRules: string;
  cwd: string;
  signal: AbortSignal;
  /** Модель для этой задачи в терминах исполнителя; не задана — его модель по умолчанию. */
  model?: string;
  /** Уточнение: продолжить сессию исполнителя, в которой выполнялась прежняя задача диалога. */
  resume?: { sessionId: string };
}

export interface Executor {
  readonly id: ExecutorId;
  status(): Promise<ExecutorStatus>;
  /** Поток завершается после done/failed либо молча — при отмене через signal. */
  run(request: ExecutorRequest): AsyncIterable<ExecutorEvent>;
}
