import { join } from "node:path";
import { ClaudeCodeSessions } from "./agents/claude-code/sessions.ts";
import { AgentMonitor } from "./agents/monitor.ts";
import { normalizeContext } from "./context/normalize.ts";
import { cleanupWorkdirs, defaultDataDir } from "./context/workdir.ts";
import { ClaudeCodeExecutor, type ClaudeCodeOptions } from "./executors/claude-code/adapter.ts";
import { ApprovalSocket } from "./executors/claude-code/socket.ts";
import type { Executor } from "./executors/executor.ts";
import { ErrorCode, RpcError, RpcServer } from "./rpc/jsonrpc.ts";
import type {
  AgentListResult,
  AgentStepsParams,
  AgentStepsResult,
  HelloResult,
  TaskApproveParams,
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
import { ActiveDialogError, ApprovalError, FollowUpError, PermissionError, TaskManager } from "./tasks/manager.ts";
import { isValidModel } from "./tasks/model.ts";
import { isPermissionLevel } from "./tasks/permission.ts";

const VERSION = "0.7.0";

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

const dataDir = defaultDataDir();
const tasksDir = join(dataDir, "tasks");
// История читается и приводится в порядок до первого запроса оболочки.
const history = await openHistory(dataDir, { log });
// Канал подтверждений: мост Claude Code приносит сюда действия, которые ждут ответа человека.
// Не открылся (например, путь к каталогу данных слишком длинный для unix-сокета) — ядро работает,
// но исполнитель отвечает на каждую задачу понятной ошибкой.
let approvals: ApprovalSocket | undefined;
try {
  approvals = await ApprovalSocket.open(dataDir, { log });
} catch (error) {
  log(error instanceof Error ? error.message : String(error));
}

const claudeOptions: ClaudeCodeOptions = {};
if (process.env.LUNA_CLAUDE_BIN) claudeOptions.binary = process.env.LUNA_CLAUDE_BIN;
if (process.env.LUNA_CLAUDE_MODEL) claudeOptions.model = process.env.LUNA_CLAUDE_MODEL;
if (approvals) claudeOptions.approvals = approvals;
const executors: Executor[] = [new ClaudeCodeExecutor(claudeOptions)];
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
  const { prompt, executor, context: rawContext, followUpOf, model, permission } = asObject(params) as Partial<TaskSubmitParams>;
  if (typeof prompt !== "string" || prompt.trim() === "") {
    throw new RpcError(ErrorCode.InvalidParams, "prompt must be a non-empty string");
  }
  if (model !== undefined && !isValidModel(model)) {
    throw new RpcError(ErrorCode.InvalidParams, "invalid model");
  }
  // Форма — здесь, поддержка исполнителем — в менеджере: у уточнения исполнитель известен только ему.
  if (permission !== undefined && !isPermissionLevel(permission)) {
    throw new RpcError(ErrorCode.InvalidParams, "invalid permission");
  }
  const submitTask = (submit: TaskSubmitParams) => {
    try {
      return { task: tasks.submit(submit) };
    } catch (error) {
      if (error instanceof FollowUpError || error instanceof PermissionError) throw new RpcError(ErrorCode.InvalidParams, error.message);
      throw error;
    }
  };
  if (followUpOf !== undefined) {
    if (typeof followUpOf !== "string") throw new RpcError(ErrorCode.InvalidParams, "followUpOf must be a string");
    // Уточнение идёт тому же исполнителю и без нового контекста: диалог — о том, с чего начался.
    if (rawContext !== undefined) throw new RpcError(ErrorCode.InvalidParams, "context is not allowed with followUpOf");
    if (executor !== undefined) throw new RpcError(ErrorCode.InvalidParams, "executor is not allowed with followUpOf");
    // Модель уточнения необязательна: без неё менеджер берёт модель продолжаемой задачи. Уровень —
    // свой у каждого уточнения: без него `manual`.
    return submitTask({ prompt, followUpOf, ...(model !== undefined ? { model } : {}), ...(permission !== undefined ? { permission } : {}) });
  }
  if (executor !== undefined && !executors.some((candidate) => candidate.id === executor)) {
    throw new RpcError(ErrorCode.InvalidParams, `unknown executor: ${String(executor)}`);
  }
  const submit: TaskSubmitParams = { prompt };
  if (executor !== undefined) submit.executor = executor;
  if (model !== undefined) submit.model = model;
  if (permission !== undefined) submit.permission = permission;
  const context = normalizeContext(rawContext);
  if (context) submit.context = context;
  return submitTask(submit);
});

rpc.method("task.cancel", (params) => {
  const { taskId } = asObject(params) as Partial<TaskCancelParams>;
  if (typeof taskId !== "string") throw new RpcError(ErrorCode.InvalidParams, "taskId must be a string");
  tasks.cancel(taskId);
  return {};
});

rpc.method("task.approve", (params) => {
  const { taskId, approvalId, allow } = asObject(params) as Partial<TaskApproveParams>;
  if (typeof taskId !== "string") throw new RpcError(ErrorCode.InvalidParams, "taskId must be a string");
  if (typeof approvalId !== "string") throw new RpcError(ErrorCode.InvalidParams, "approvalId must be a string");
  if (typeof allow !== "boolean") throw new RpcError(ErrorCode.InvalidParams, "allow must be a boolean");
  try {
    tasks.approve(taskId, approvalId, allow);
  } catch (error) {
    if (error instanceof ApprovalError) throw new RpcError(ErrorCode.InvalidParams, error.message);
    throw error;
  }
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
// Файл сокета снимается до выхода: следующему запуску нечего подчищать.
approvals?.close();
history?.close();
process.exit(0);
