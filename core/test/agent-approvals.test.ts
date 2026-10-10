import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { AgentApprovalError, AgentApprovals } from "../src/agents/approvals.ts";
import { HOOK_WRAPPER_NAME, hookWrapperPath, hookWrapperScript, writeHookWrapper } from "../src/agents/claude-code/hook-wrapper.ts";
import { permissionHook } from "../src/agents/claude-code/permission-hook.ts";
import { AgentMonitor } from "../src/agents/monitor.ts";
import type { AgentSource } from "../src/agents/source.ts";
import { BRIDGE_PATH } from "../src/executors/claude-code/adapter.ts";
import { AGENT_DENIED_MESSAGE, COMMAND_LIMIT } from "../src/executors/claude-code/approval.ts";
import { ApprovalSocket, type AgentHookRequest } from "../src/executors/claude-code/socket.ts";
import type { PauseRequest } from "../src/executors/executor.ts";
import type { AgentSession, AgentState } from "../src/rpc/protocol.gen.ts";

// Подтверждения чужих сессий (LUNA-53): менеджер ожиданий, монитор, обработчик хука `PermissionRequest`
// и режим `agent-hook` моста. Вход хука — записанный stdin реального запуска Claude Code 2.1.296
// (`agent-permission-request.hook.jsonl`, см. fixtures/claude-code/README.md).

const SHOP = "11111111-1111-4111-8111-111111111111";
const API = "22222222-2222-4222-8222-222222222222";

const WRITE: PauseRequest = { tool: "Write", kind: "write", summary: "Записать файл", target: "/work/shop/a.txt", detail: "hi" };

function session(id: string, state: AgentState = "waiting", updatedAt = 1000, cwd = "/work/shop"): AgentSession {
  return {
    id, agent: "claude-code", pid: 100, cwd, project: "shop", state, host: { kind: "unknown" }, startedAt: 1, updatedAt,
    ...(state === "waiting" ? { waitingFor: "permission prompt" } : {}),
  };
}

const hookInputs = (): string[] =>
  readFileSync(fileURLToPath(new URL("./fixtures/claude-code/agent-permission-request.hook.jsonl", import.meta.url)), "utf8")
    .trimEnd()
    .split("\n");

/** Дождаться, пока обещание не завершится: проверка «ответа ещё нет» без зависания теста. */
async function settledWithin<T>(promise: Promise<T>, ms = 30): Promise<T | "pending"> {
  return Promise.race([promise, new Promise<"pending">((resolve) => setTimeout(() => resolve("pending"), ms))]);
}

// --- менеджер ожиданий -------------------------------------------------------------------------

test("менеджер: запрос виден в сессии, ответ человека возвращается хуку и снимает запрос", async () => {
  const approvals = new AgentApprovals();
  const changes: number[] = [];
  approvals.subscribe(() => changes.push(changes.length));
  const outcome = approvals.ask(SHOP, WRITE);
  assert.equal(changes.length, 1);

  const [shown] = approvals.attach([session(SHOP), session(API)]);
  assert.ok(shown?.approval);
  assert.equal(shown.approval.summary, "Записать файл");
  assert.equal(shown.approval.target, "/work/shop/a.txt");
  assert.equal(shown.approval.detail, "hi");
  assert.equal(shown.approval.tool, "Write");
  assert.equal(approvals.attach([session(API)])[0]?.approval, undefined, "чужой запрос в другой сессии не виден");

  approvals.approve(SHOP, shown.approval.id, true);
  assert.equal(await outcome, "allow");
  assert.equal(approvals.attach([session(SHOP)])[0]?.approval, undefined);
  assert.equal(changes.length, 2, "ответ — изменение");

  const denied = approvals.ask(SHOP, WRITE);
  const id = approvals.attach([session(SHOP)])[0]?.approval?.id;
  assert.ok(id);
  approvals.approve(SHOP, id, false);
  assert.equal(await denied, "deny");
});

test("менеджер: чужой id, неизвестная сессия и повторный ответ — ошибка адресата", async () => {
  const approvals = new AgentApprovals();
  const outcome = approvals.ask(SHOP, WRITE);
  const id = approvals.attach([session(SHOP)])[0]?.approval?.id as string;

  assert.throws(() => approvals.approve(SHOP, "не-тот", true), AgentApprovalError);
  assert.throws(() => approvals.approve(API, id, true), AgentApprovalError);
  assert.equal(await settledWithin(outcome), "pending", "ошибочные ответы запрос не снимают");

  approvals.approve(SHOP, id, true);
  assert.equal(await outcome, "allow");
  assert.throws(() => approvals.approve(SHOP, id, true), AgentApprovalError, "повторный ответ");
});

test("менеджер: сессия пропала из реестра — запрос снят, хук получает «нет решения»", async () => {
  const approvals = new AgentApprovals();
  const outcome = approvals.ask(SHOP, WRITE);
  assert.equal(approvals.reconcile([session(SHOP)]), false);
  assert.equal(approvals.reconcile([session(API)]), true);
  assert.equal(await outcome, "none");
  assert.equal(approvals.attach([session(SHOP)])[0]?.approval, undefined);
});

test("менеджер: ответили в терминале — сессия вышла из waiting, запрос снят; свежий запрос реестр не снимает", async () => {
  const approvals = new AgentApprovals();
  // Реестр мог отстать от хука: сессия ещё busy, а запрос уже пришёл — ждём, а не снимаем.
  const early = approvals.ask(SHOP, WRITE);
  assert.equal(approvals.reconcile([session(SHOP, "working")]), false);
  assert.equal(await settledWithin(early), "pending");
  assert.equal(approvals.reconcile([session(SHOP, "waiting")]), false);
  assert.equal(approvals.reconcile([session(SHOP, "working", 2000)]), true);
  assert.equal(await early, "none");
});

test("менеджер: несколько запросов одной сессии — очередь, показан самый ранний", async () => {
  const approvals = new AgentApprovals();
  const first = approvals.ask(SHOP, { ...WRITE, target: "/work/shop/p1.txt" });
  const second = approvals.ask(SHOP, { ...WRITE, target: "/work/shop/p2.txt" });
  const other = approvals.ask(API, { ...WRITE, target: "/work/api/x.txt" });

  const shown = approvals.attach([session(SHOP), session(API)]);
  assert.equal(shown[0]?.approval?.target, "/work/shop/p1.txt");
  assert.equal(shown[1]?.approval?.target, "/work/api/x.txt", "две сессии — два независимых запроса");

  approvals.approve(SHOP, shown[0]?.approval?.id as string, true);
  assert.equal(await first, "allow");
  assert.equal(approvals.attach([session(SHOP)])[0]?.approval?.target, "/work/shop/p2.txt");
  assert.equal(await settledWithin(second), "pending");
  assert.equal(await settledWithin(other), "pending");
});

test("менеджер: первый диалог закрыли в терминале, CLI показал второй — прежний запрос снят, следующий показан", async () => {
  const approvals = new AgentApprovals();
  const first = approvals.ask(SHOP, { ...WRITE, target: "/work/shop/p1.txt" });
  const second = approvals.ask(SHOP, { ...WRITE, target: "/work/shop/p2.txt" });
  // Диалог первого вызова: запись реестра с updatedAt 4000.
  assert.equal(approvals.reconcile([session(SHOP, "waiting", 4000)]), false);
  // Ответ в терминале (busy на долю секунды опрос мог пропустить) и новый диалог — updatedAt 4800.
  assert.equal(approvals.reconcile([session(SHOP, "waiting", 4800)]), true);
  assert.equal(await first, "none");
  assert.equal(approvals.attach([session(SHOP, "waiting", 4800)])[0]?.approval?.target, "/work/shop/p2.txt");
  assert.equal(await settledWithin(second), "pending");
  // Единственный запрос смена записи реестра не снимает: у него нет соседа, который показал бы смену диалога.
  assert.equal(approvals.reconcile([session(SHOP, "waiting", 5200)]), false);
});

test("менеджер: обрыв хука снимает запрос; shutdown закрывает все без решения", async () => {
  const approvals = new AgentApprovals();
  const abort = new AbortController();
  const aborted = approvals.ask(SHOP, WRITE, abort.signal);
  const kept = approvals.ask(API, WRITE);
  abort.abort();
  assert.equal(await aborted, "none");
  assert.equal(approvals.attach([session(SHOP), session(API)])[0]?.approval, undefined);
  assert.ok(approvals.attach([session(SHOP), session(API)])[1]?.approval);

  approvals.shutdown();
  assert.equal(await kept, "none");
  assert.equal(await approvals.ask(SHOP, WRITE), "none", "после shutdown новые запросы не ставятся");
});

// --- монитор -----------------------------------------------------------------------------------

function monitorWith(sessions: () => AgentSession[], approvals: AgentApprovals) {
  const source: AgentSource = { agent: "claude-code", sessions: async () => sessions(), steps: async () => undefined };
  const emitted: AgentSession[][] = [];
  const monitor = new AgentMonitor({ sources: [source], approvals, emit: (list) => emitted.push(list) });
  return { monitor, emitted };
}

test("монитор: approval в agents.list и agents.changed сразу при появлении и снятии, без такта опроса", async () => {
  const approvals = new AgentApprovals();
  const { monitor, emitted } = monitorWith(() => [session(SHOP, "waiting", 1000)], approvals);
  assert.equal((await monitor.list())[0]?.approval, undefined);

  const outcome = approvals.ask(SHOP, WRITE);
  assert.equal(emitted.length, 1, "запрос появился — сразу уведомление");
  const approval = emitted[0]?.[0]?.approval;
  assert.equal(approval?.summary, "Записать файл");
  assert.equal((await monitor.list())[0]?.approval?.id, approval?.id, "agents.list несёт тот же запрос");

  approvals.approve(SHOP, approval?.id as string, true);
  assert.equal(await outcome, "allow");
  assert.equal(emitted.length, 2);
  assert.equal(emitted[1]?.[0]?.approval, undefined);
});

test("монитор: сессия ушла из waiting без ответа Luna — запрос снят следующим проходом", async () => {
  const approvals = new AgentApprovals();
  let state: AgentState = "waiting";
  const { monitor, emitted } = monitorWith(() => [session(SHOP, state, state === "waiting" ? 1000 : 2000)], approvals);
  await monitor.list();
  const outcome = approvals.ask(SHOP, WRITE);
  await monitor.refresh();
  assert.equal(await settledWithin(outcome), "pending");

  state = "working";
  await monitor.refresh();
  assert.equal(await outcome, "none");
  assert.equal(emitted.at(-1)?.[0]?.approval, undefined);
  assert.equal(emitted.at(-1)?.[0]?.state, "working");
});

// --- обработчик хука ---------------------------------------------------------------------------

function hookRequest(call: Partial<AgentHookRequest["call"]> & { tool_name: string }, over: Partial<AgentHookRequest> = {}): AgentHookRequest {
  return { kind: "agent-hook", session: SHOP, cwd: "/work/shop", call: { input: {}, ...call }, ...over };
}

test("обработчик хука: «нет решения» для неизвестной сессии, каталога задач Luna, чужого инструмента и длинной команды", async () => {
  const approvals = new AgentApprovals();
  const known = [session(SHOP), session("33333333-3333-4333-8333-333333333333", "waiting", 1, "/luna/tasks/abc")];
  const hook = permissionHook({
    approvals,
    find: async (id) => known.find((item) => item.id === id),
    excludeCwd: ["/luna/tasks"],
  });
  const signal = new AbortController().signal;
  const write = { tool_name: "Write", input: { file_path: "a.txt", content: "x" } };

  assert.deepEqual(await hook(hookRequest(write, { session: API }), signal), { behavior: "none" }, "сессия ядру неизвестна");
  assert.deepEqual(
    await hook(hookRequest(write, { session: "33333333-3333-4333-8333-333333333333", cwd: "/luna/tasks/abc" }), signal),
    { behavior: "none" },
    "задача самой Luna",
  );
  assert.deepEqual(await hook(hookRequest(write, { cwd: "/luna/tasks/abc" }), signal), { behavior: "none" }, "каталог из запроса внутри каталога задач");
  assert.deepEqual(await hook(hookRequest({ tool_name: "AskUserQuestion", input: { questions: [] } }), signal), { behavior: "none" }, "вопрос агента — LUNA-28");
  assert.deepEqual(await hook(hookRequest({ tool_name: "WebFetch", input: { url: "https://example.com" } }), signal), { behavior: "none" });
  assert.deepEqual(
    await hook(hookRequest({ tool_name: "Bash", input: { command: "x".repeat(COMMAND_LIMIT + 1) } }), signal),
    { behavior: "none" },
    "команду длиннее предела человек не прочтёт",
  );
  assert.equal(approvals.attach([session(SHOP)])[0]?.approval, undefined, "ни один из этих запросов в списке не появился");
});

test("обработчик хука: запрос показывается как у задач, подпись каталога — сессии; ответ человека возвращается хуку", async () => {
  const approvals = new AgentApprovals();
  const hook = permissionHook({ approvals, find: async (id) => (id === SHOP ? session(SHOP) : undefined), excludeCwd: [] });
  const signal = new AbortController().signal;

  const answered = hook(hookRequest({ tool_name: "Bash", input: { command: "npm test", description: "Прогон тестов" } }, { cwd: "/work/shop/packages/web" }), signal);
  await settledWithin(answered, 5);
  const approval = approvals.attach([session(SHOP)])[0]?.approval;
  assert.equal(approval?.kind, "shell");
  assert.equal(approval?.target, "npm test");
  assert.match(approval?.detail ?? "", /Каталог сессии: \/work\/shop\/packages\/web/);
  assert.doesNotMatch(approval?.detail ?? "", /Каталог задачи/);

  approvals.approve(SHOP, approval?.id as string, false);
  assert.deepEqual(await answered, { behavior: "deny", message: AGENT_DENIED_MESSAGE });
});

// --- мост: режим agent-hook ----------------------------------------------------------------------

interface HookRun {
  code: number | null;
  stdout: string;
  stderr: string;
}

async function runAgentHook(dataDir: string, input: string, command = [process.execPath, BRIDGE_PATH, "agent-hook", dataDir]): Promise<HookRun> {
  const [file, ...args] = command as [string, ...string[]];
  const child = spawn(file, args, { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
  child.stdin.end(input);
  const code = await new Promise<number | null>((resolve) => child.once("close", resolve));
  return { code, stdout, stderr };
}

const tempDir = () => mkdtempSync(join(tmpdir(), "luna-ah-"));

/** Ядро в миниатюре: сокет, менеджер, монитор с одной ждущей сессией и обработчик хука. */
async function miniCore(options: { sessions?: AgentSession[] } = {}) {
  const dataDir = tempDir();
  const socket = await ApprovalSocket.open(dataDir);
  const approvals = new AgentApprovals();
  const sessions = options.sessions ?? [session(SHOP)];
  const { monitor } = monitorWith(() => sessions, approvals);
  socket.setAgentHook(permissionHook({ approvals, find: (id) => monitor.find(id), excludeCwd: [] }));
  await monitor.list();
  /** Ждёт, пока запрос появится у сессии, и отвечает на него. */
  const answer = async (allow: boolean, sessionId = SHOP) => {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const approval = (await monitor.list()).find((item) => item.id === sessionId)?.approval;
      if (approval) {
        approvals.approve(sessionId, approval.id, allow);
        return approval;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error("запрос не появился");
  };
  return { dataDir, socket, approvals, monitor, answer, close: () => (approvals.shutdown(), socket.close()) };
}

test("agent-hook: allow — ровно ответ PermissionRequest, deny — с причиной «Отклонено в Luna», код 0", async () => {
  const core = await miniCore();
  const [input] = hookInputs() as [string];

  const allowed = runAgentHook(core.dataDir, input);
  const approval = await core.answer(true);
  assert.equal(approval.summary, "Записать файл");
  assert.equal(approval.target, "/work/shop/p1.txt");
  const allowedRun = await allowed;
  assert.equal(allowedRun.code, 0, allowedRun.stderr);
  assert.equal(allowedRun.stdout, '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n');

  const denied = runAgentHook(core.dataDir, input);
  await core.answer(false);
  const deniedRun = await denied;
  assert.equal(deniedRun.code, 0, deniedRun.stderr);
  assert.deepEqual(JSON.parse(deniedRun.stdout), {
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "deny", message: "Отклонено в Luna" } },
  });
  core.close();
});

test("agent-hook: нет решения у ядра — пустой stdout и код 0, как и при любой беде", async () => {
  const [input] = hookInputs() as [string];

  // Нет сокета (Luna закрыта).
  const empty = tempDir();
  const noSocket = await runAgentHook(empty, input);
  assert.deepEqual([noSocket.code, noSocket.stdout], [0, ""]);
  const noDir = await runAgentHook(join(empty, "нет-такого"), input);
  assert.deepEqual([noDir.code, noDir.stdout], [0, ""]);

  // Сессия ядру неизвестна.
  const core = await miniCore({ sessions: [session(API)] });
  const unknown = await runAgentHook(core.dataDir, input);
  assert.deepEqual([unknown.code, unknown.stdout], [0, ""]);

  // Вход не JSON, не объект, без session_id, чужое событие.
  for (const garbage of ["", "не json", "[1]", JSON.stringify({ tool_name: "Write" }), JSON.stringify({ ...JSON.parse(input), hook_event_name: "PreToolUse" })]) {
    const run = await runAgentHook(core.dataDir, garbage);
    assert.deepEqual([run.code, run.stdout], [0, ""], `вход ${garbage.slice(0, 30)}`);
  }
  core.close();

  // Остаток сокета без ядра: соединиться нельзя — тоже без решения.
  const stale = tempDir();
  writeFileSync(join(stale, "approvals-0123456789abcdef.sock"), "");
  const staleRun = await runAgentHook(stale, input);
  assert.deepEqual([staleRun.code, staleRun.stdout], [0, ""]);
});

test("agent-hook: ядро закрыло соединение или ответило непонятно — без решения; ядро остановили — хук отпущен", async () => {
  const [input] = hookInputs() as [string];
  // Подставное ядро, которое отвечает мусором либо закрывает соединение.
  for (const reply of ["мусор", "close", '{"behavior":"что-то"}', "[]"]) {
    const dataDir = tempDir();
    const path = join(dataDir, "approvals-aaaaaaaaaaaaaaaa.sock");
    const server = createServer((socket) => {
      socket.setEncoding("utf8");
      createInterface({ input: socket }).once("line", () => (reply === "close" ? socket.end() : socket.end(`${reply}\n`)));
    });
    await new Promise<void>((resolve) => server.listen(path, resolve));
    const run = await runAgentHook(dataDir, input);
    server.close();
    assert.deepEqual([run.code, run.stdout], [0, ""], `ответ ядра: ${reply}`);
  }

  const core = await miniCore();
  const waiting = runAgentHook(core.dataDir, input);
  for (let attempt = 0; attempt < 200 && !(await core.monitor.list())[0]?.approval; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  core.close();
  const run = await waiting;
  assert.deepEqual([run.code, run.stdout], [0, ""]);
});

test("agent-hook: хук убит (timeout) — запрос снимается, а не висит в карточке", async () => {
  const core = await miniCore();
  const [input] = hookInputs() as [string];
  const child = spawn(process.execPath, [BRIDGE_PATH, "agent-hook", core.dataDir], { stdio: ["pipe", "pipe", "pipe"] });
  child.stdin.end(input);
  for (let attempt = 0; attempt < 200 && !(await core.monitor.list())[0]?.approval; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.ok((await core.monitor.list())[0]?.approval);
  child.kill("SIGKILL");
  for (let attempt = 0; attempt < 200 && (await core.monitor.list())[0]?.approval; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal((await core.monitor.list())[0]?.approval, undefined);
  core.close();
});

test("agent-hook: два параллельных хука одной сессии — два запроса по очереди, ответы не путаются", async () => {
  const core = await miniCore();
  const [first, second] = hookInputs() as [string, string];
  const one = runAgentHook(core.dataDir, first);
  // Порядок прихода — порядок очереди: второй хук стартует, когда первый уже в очереди.
  for (let attempt = 0; attempt < 200 && !(await core.monitor.list())[0]?.approval; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  const two = runAgentHook(core.dataDir, second);
  const head = await core.answer(true);
  assert.equal(head.target, "/work/shop/p1.txt");
  assert.match((await one).stdout, /"allow"/);
  const next = await core.answer(false);
  assert.equal(next.target, "/work/shop/p2.txt");
  assert.match((await two).stdout, /"deny"/);
  core.close();
});

// --- обёртка в каталоге данных -----------------------------------------------------------------

test("обёртка: путь стабилен, файл исполняемый, пути с пробелами и кавычками подставлены без правки оболочкой", async () => {
  const dataDir = join(tempDir(), "Application Support", "it's Luna");
  mkdirSync(dataDir, { recursive: true });
  const path = await writeHookWrapper(dataDir, "/opt/node 22/bin/node", "/Applications/Luna.app/Contents/Resources/core/bridge's.js");
  assert.equal(path, hookWrapperPath(dataDir));
  assert.ok(path.endsWith(`/${HOOK_WRAPPER_NAME}`));
  assert.equal(statSync(path).mode & 0o777, 0o755);
  const text = readFileSync(path, "utf8");
  assert.match(text, /^#!\/bin\/sh\n/);
  assert.ok(text.includes(`'/opt/node 22/bin/node' '/Applications/Luna.app/Contents/Resources/core/bridge'\\''s.js' agent-hook`));
  assert.equal(text, hookWrapperScript(dataDir, "/opt/node 22/bin/node", "/Applications/Luna.app/Contents/Resources/core/bridge's.js"));
});

test("обёртка как хук: Luna закрыта — тихий выход; Luna открыта — ответ человека доходит", async () => {
  const [input] = hookInputs() as [string];
  const closed = tempDir();
  const closedPath = await writeHookWrapper(closed, process.execPath, BRIDGE_PATH);
  const quiet = await runAgentHook(closed, input, [closedPath]);
  assert.deepEqual([quiet.code, quiet.stdout, quiet.stderr], [0, "", ""]);

  const core = await miniCore();
  const wrapper = await writeHookWrapper(core.dataDir, process.execPath, BRIDGE_PATH);
  const run = runAgentHook(core.dataDir, input, [wrapper]);
  await core.answer(true);
  const done = await run;
  assert.equal(done.code, 0, done.stderr);
  assert.match(done.stdout, /"behavior":"allow"/);
  core.close();
});
