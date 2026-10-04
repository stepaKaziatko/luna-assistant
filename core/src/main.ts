import { join } from "node:path";
import { normalizeContext } from "./context/normalize.ts";
import { cleanupWorkdirs, defaultDataDir } from "./context/workdir.ts";
import { ClaudeCodeExecutor } from "./executors/claude-code/adapter.ts";
import type { Executor } from "./executors/executor.ts";
import { ErrorCode, RpcError, RpcServer } from "./rpc/jsonrpc.ts";
import type {
  HelloResult,
  TaskCancelParams,
  TaskListResult,
  TaskSubmitParams,
  TaskSubmitResult,
} from "./rpc/protocol.gen.ts";
import { TaskManager } from "./tasks/manager.ts";

const VERSION = "0.2.0";

// stdout занят протоколом — диагностика только в stderr.
function log(message: string): void {
  process.stderr.write(`[core] ${message}\n`);
}

function asObject(params: unknown): Record<string, unknown> {
  if (params === null || typeof params !== "object" || Array.isArray(params)) {
    throw new RpcError(ErrorCode.InvalidParams, "params must be an object");
  }
  return params as Record<string, unknown>;
}

const claudeOptions: { binary?: string; model?: string } = {};
if (process.env.LUNA_CLAUDE_BIN) claudeOptions.binary = process.env.LUNA_CLAUDE_BIN;
if (process.env.LUNA_CLAUDE_MODEL) claudeOptions.model = process.env.LUNA_CLAUDE_MODEL;
const executors: Executor[] = [new ClaudeCodeExecutor(claudeOptions)];

const tasksDir = join(defaultDataDir(), "tasks");
const rpc = new RpcServer(process.stdin, process.stdout);
const tasks = new TaskManager({
  executors,
  defaultExecutor: "claude-code",
  tasksDir,
  emit: (event, task) => rpc.notify(event, { task }),
});

rpc.method("core.hello", async (): Promise<HelloResult> => ({
  version: VERSION,
  executors: await Promise.all(executors.map((executor) => executor.status())),
}));

rpc.method("task.submit", (params): TaskSubmitResult => {
  const { prompt, executor, context: rawContext } = asObject(params) as Partial<TaskSubmitParams>;
  if (typeof prompt !== "string" || prompt.trim() === "") {
    throw new RpcError(ErrorCode.InvalidParams, "prompt must be a non-empty string");
  }
  if (executor !== undefined && !executors.some((candidate) => candidate.id === executor)) {
    throw new RpcError(ErrorCode.InvalidParams, `unknown executor: ${String(executor)}`);
  }
  const submit: TaskSubmitParams = { prompt };
  if (executor !== undefined) submit.executor = executor;
  const context = normalizeContext(rawContext);
  if (context) submit.context = context;
  return { task: tasks.submit(submit) };
});

rpc.method("task.cancel", (params) => {
  const { taskId } = asObject(params) as Partial<TaskCancelParams>;
  if (typeof taskId !== "string") throw new RpcError(ErrorCode.InvalidParams, "taskId must be a string");
  tasks.cancel(taskId);
  return {};
});

rpc.method("task.list", (): TaskListResult => ({ tasks: tasks.list() }));

void cleanupWorkdirs(tasksDir).catch((error) => log(`workdir cleanup failed: ${String(error)}`));
log(`started v${VERSION}, data dir: ${defaultDataDir()}`);

// stdin закрывается, когда shell завершился: оставлять исполнителей без хозяина нельзя.
await rpc.listen();
tasks.cancelAll();
process.exit(0);
