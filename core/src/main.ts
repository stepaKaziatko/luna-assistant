import { join } from "node:path";
import { ClaudeCodeSessions } from "./agents/claude-code/sessions.ts";
import { AgentMonitor } from "./agents/monitor.ts";
import { normalizeContext } from "./context/normalize.ts";
import { cleanupWorkdirs, defaultDataDir } from "./context/workdir.ts";
import { ClaudeCodeExecutor } from "./executors/claude-code/adapter.ts";
import type { Executor } from "./executors/executor.ts";
import { ErrorCode, RpcError, RpcServer } from "./rpc/jsonrpc.ts";
import type {
  AgentListResult,
  AgentStepsParams,
  AgentStepsResult,
  HelloResult,
  TaskCancelParams,
  TaskClearResult,
  TaskDeleteParams,
  TaskDeleteResult,
  TaskListParams,
  TaskListResult,
  TaskSubmitParams,
  TaskSubmitResult,
} from "./rpc/protocol.gen.ts";
import { openHistory } from "./tasks/history.ts";
import { ActiveDialogError, FollowUpError, TaskManager } from "./tasks/manager.ts";
import { isValidModel } from "./tasks/model.ts";

const VERSION = "0.5.0";

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

const dataDir = defaultDataDir();
const tasksDir = join(dataDir, "tasks");
// История читается и приводится в порядок до первого запроса оболочки.
const history = await openHistory(dataDir, { log });
const rpc = new RpcServer(process.stdin, process.stdout);
const tasks = new TaskManager({
  executors,
  defaultExecutor: "claude-code",
  tasksDir,
  history,
  emit: (event, task) => rpc.notify(event, { task }),
});

// Сессии агентов, запущенные не Luna. Собственные задачи Luna в этот список не попадают.
const agents = new AgentMonitor({
  sources: [new ClaudeCodeSessions({ excludeCwd: [tasksDir] })],
  emit: (sessions) => rpc.notify("agents.changed", { sessions }),
  log,
});

rpc.method("core.hello", async (): Promise<HelloResult> => ({
  version: VERSION,
  executors: await Promise.all(executors.map((executor) => executor.status())),
}));

rpc.method("task.submit", (params): TaskSubmitResult => {
  const { prompt, executor, context: rawContext, followUpOf, model } = asObject(params) as Partial<TaskSubmitParams>;
  if (typeof prompt !== "string" || prompt.trim() === "") {
    throw new RpcError(ErrorCode.InvalidParams, "prompt must be a non-empty string");
  }
  if (model !== undefined && !isValidModel(model)) {
    throw new RpcError(ErrorCode.InvalidParams, "invalid model");
  }
  if (followUpOf !== undefined) {
    if (typeof followUpOf !== "string") throw new RpcError(ErrorCode.InvalidParams, "followUpOf must be a string");
    // Уточнение идёт тому же исполнителю и без нового контекста: диалог — о том, с чего начался.
    if (rawContext !== undefined) throw new RpcError(ErrorCode.InvalidParams, "context is not allowed with followUpOf");
    if (executor !== undefined) throw new RpcError(ErrorCode.InvalidParams, "executor is not allowed with followUpOf");
    // Модель уточнения необязательна: без неё менеджер берёт модель продолжаемой задачи.
    try {
      return { task: tasks.submit({ prompt, followUpOf, ...(model !== undefined ? { model } : {}) }) };
    } catch (error) {
      if (error instanceof FollowUpError) throw new RpcError(ErrorCode.InvalidParams, error.message);
      throw error;
    }
  }
  if (executor !== undefined && !executors.some((candidate) => candidate.id === executor)) {
    throw new RpcError(ErrorCode.InvalidParams, `unknown executor: ${String(executor)}`);
  }
  const submit: TaskSubmitParams = { prompt };
  if (executor !== undefined) submit.executor = executor;
  if (model !== undefined) submit.model = model;
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

// Оболочка зовёт task.list и без params — тогда это обычный список.
rpc.method("task.list", (params): TaskListResult => {
  if (params === undefined || params === null) return { tasks: tasks.list() };
  const { query } = asObject(params) as Partial<TaskListParams>;
  if (query !== undefined && typeof query !== "string") throw new RpcError(ErrorCode.InvalidParams, "query must be a string");
  return { tasks: tasks.list(query === undefined ? {} : { query }) };
});

rpc.method("task.delete", async (params): Promise<TaskDeleteResult> => {
  const { taskId } = asObject(params) as Partial<TaskDeleteParams>;
  if (typeof taskId !== "string") throw new RpcError(ErrorCode.InvalidParams, "taskId must be a string");
  try {
    return { deleted: await tasks.delete(taskId) };
  } catch (error) {
    if (error instanceof ActiveDialogError) throw new RpcError(ErrorCode.InvalidParams, error.message);
    throw error;
  }
});

rpc.method("task.clear", async (params): Promise<TaskClearResult> => {
  if (params !== undefined && params !== null) asObject(params);
  return { deleted: await tasks.clear() };
});

rpc.method("agents.list", async (): Promise<AgentListResult> => ({ sessions: await agents.list() }));

rpc.method("agents.steps", async (params): Promise<AgentStepsResult> => {
  const { sessionId, detail } = asObject(params) as Partial<AgentStepsParams>;
  if (typeof sessionId !== "string") throw new RpcError(ErrorCode.InvalidParams, "sessionId must be a string");
  if (detail !== undefined && typeof detail !== "boolean") throw new RpcError(ErrorCode.InvalidParams, "detail must be a boolean");
  return { steps: await agents.steps(sessionId, detail === true) };
});

agents.start();
void cleanupWorkdirs(tasksDir).catch((error) => log(`workdir cleanup failed: ${String(error)}`));
log(`started v${VERSION}, data dir: ${dataDir}`);

// stdin закрывается, когда shell завершился: оставлять исполнителей без хозяина нельзя.
// Незавершённые задачи записываются в историю прерванными — запись синхронная, до выхода.
await rpc.listen();
agents.stop();
tasks.shutdown();
history?.close();
process.exit(0);
