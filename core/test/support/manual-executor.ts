import type { Executor, ExecutorEvent, ExecutorRequest } from "../../src/executors/executor.ts";

/** Исполнитель, каждым запуском которого тест управляет вручную. */
export class ManualExecutor implements Executor {
  readonly id = "claude-code";
  readonly runs: { request: ExecutorRequest; push: (event: ExecutorEvent) => void }[] = [];

  async status() {
    return { id: this.id, available: true } as const;
  }

  async *run(request: ExecutorRequest): AsyncGenerator<ExecutorEvent> {
    const pending: ExecutorEvent[] = [];
    let wake = () => {};
    this.runs.push({
      request,
      push: (event) => {
        pending.push(event);
        wake();
      },
    });
    request.signal.addEventListener("abort", () => wake());

    while (!request.signal.aborted) {
      const event = pending.shift();
      if (!event) {
        await new Promise<void>((resolve) => (wake = resolve));
        continue;
      }
      yield event;
      if (event.type === "done" || event.type === "failed") return;
    }
  }
}
