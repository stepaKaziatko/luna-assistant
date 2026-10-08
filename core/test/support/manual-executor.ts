import type { Executor, ExecutorEvent, ExecutorRequest } from "../../src/executors/executor.ts";
import type { ExecutorStatus, PermissionLevel } from "../../src/rpc/protocol.gen.ts";

/** Исполнитель, каждым запуском которого тест управляет вручную. */
export class ManualExecutor implements Executor {
  readonly id = "claude-code";
  readonly permissionLevels: readonly PermissionLevel[];
  readonly runs: { request: ExecutorRequest; push: (event: ExecutorEvent) => void }[] = [];

  /** `permissionLevels` — какие уровни исполнитель объявляет; по умолчанию все известные. */
  constructor(permissionLevels: readonly PermissionLevel[] = ["manual", "edit_automatically"]) {
    this.permissionLevels = permissionLevels;
  }

  async status(): Promise<ExecutorStatus> {
    return { id: this.id, available: true, permissionLevels: [...this.permissionLevels] };
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
