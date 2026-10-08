import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BRIDGE_PATH } from "../src/executors/claude-code/adapter.ts";
import type { BridgeRequest } from "../src/executors/claude-code/socket.ts";
import { quietPeriod, until } from "./support/wait.ts";

const fixture = (name: string) => readFileSync(fileURLToPath(new URL(`./fixtures/claude-code/${name}`, import.meta.url)), "utf8");

interface Reply {
  id?: number;
  result?: { protocolVersion?: string; serverInfo?: { name: string }; capabilities?: unknown; tools?: { name: string }[]; content?: { type: string; text: string }[] };
  error?: { code: number; message: string };
}

/** Подставное ядро: отвечает на каждый запрос моста одним решением и запоминает, что получило. */
async function fakeCore(decision: (request: BridgeRequest) => unknown): Promise<{ path: string; server: Server; requests: BridgeRequest[] }> {
  const requests: BridgeRequest[] = [];
  // Короткий путь: предел unix-сокета на macOS — 104 байта.
  const path = join(mkdtempSync(join(tmpdir(), "luna-b-")), "core.sock");
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    createInterface({ input: socket }).once("line", (line) => {
      const request = JSON.parse(line) as BridgeRequest;
      requests.push(request);
      socket.end(`${JSON.stringify(decision(request))}\n`);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  return { path, server, requests };
}

/** Мост дочерним процессом, как его запускает CLI: строки фикстуры — в stdin, ответы — из stdout. */
async function runBridge(socketPath: string, input: string): Promise<Reply[]> {
  const child = spawn(process.execPath, [BRIDGE_PATH, socketPath, "run-1"], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
  const replies: Reply[] = [];
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on("line", (line) => replies.push(JSON.parse(line) as Reply));
  child.stdin.end(input);
  const code = await new Promise<number | null>((resolve) => child.once("close", resolve));
  assert.equal(code, 0, `мост завершился с кодом ${code}: ${stderr}`);
  return replies;
}

const decisionOf = (reply: Reply | undefined) => {
  const text = reply?.result?.content?.[0]?.text;
  assert.ok(text, `в ответе нет текста решения: ${JSON.stringify(reply)}`);
  assert.equal(reply?.result?.content?.[0]?.type, "text");
  return JSON.parse(text) as Record<string, unknown>;
};

test("мост на записанном обмене: initialize → tools/list → tools/call; разрешение ядра уходит CLI как allow с тем же входом", async () => {
  const core = await fakeCore((request) => ({ behavior: "allow", updatedInput: request.call.input }));
  try {
    const replies = await runBridge(core.path, fixture("approval-allow.jsonl"));
    // Уведомление `notifications/initialized` ответа не имеет: три ответа на четыре строки.
    assert.deepEqual(replies.map((reply) => reply.id), [0, 1, 2]);
    assert.equal(replies[0]?.result?.protocolVersion, "2025-11-25", "версия протокола — та, что назвал клиент");
    assert.equal(replies[0]?.result?.serverInfo?.name, "luna");
    assert.ok(replies[0]?.result?.capabilities);
    assert.deepEqual(replies[1]?.result?.tools?.map((tool) => tool.name), ["approve"]);

    const input = { file_path: "/tmp/luna-task/hello.txt", content: "hi" };
    assert.deepEqual(decisionOf(replies[2]), { behavior: "allow", updatedInput: input });
    assert.equal(core.requests.length, 1);
    assert.equal(core.requests[0]?.run, "run-1");
    assert.equal(core.requests[0]?.call.tool_name, "Write");
    assert.deepEqual(core.requests[0]?.call.input, input);
    assert.equal(core.requests[0]?.call.tool_use_id, "toolu_01QKguoSLJ3A4XZKmbtaDbQx");
  } finally {
    core.server.close();
  }
});

test("мост: отказ ядра уходит CLI как deny с причиной", async () => {
  const core = await fakeCore(() => ({ behavior: "deny", message: "Пользователь отклонил действие в Luna" }));
  try {
    const replies = await runBridge(core.path, fixture("approval-deny.jsonl"));
    assert.deepEqual(decisionOf(replies[2]), { behavior: "deny", message: "Пользователь отклонил действие в Luna" });
    assert.equal(core.requests[0]?.call.tool_use_id, "toolu_0129LffrhV8Ks1Ax2iSDJn6c");
  } finally {
    core.server.close();
  }
});

test("мост: ядро недоступно — deny с причиной, действие не выполняется; CLI получает ответы на остальные запросы", async () => {
  const replies = await runBridge(join(tmpdir(), "luna-no-such-core.sock"), fixture("approval-allow.jsonl"));
  assert.deepEqual(replies.map((reply) => reply.id), [0, 1, 2]);
  const decision = decisionOf(replies[2]);
  assert.equal(decision.behavior, "deny");
  assert.match(String(decision.message), /^Luna недоступна: /);
});

test("мост: незнакомый метод — ошибка Method not found, чужой инструмент — ошибка params; stdout — только JSON-RPC", async () => {
  const core = await fakeCore(() => ({ behavior: "allow", updatedInput: {} }));
  try {
    const replies = await runBridge(core.path, [
      JSON.stringify({ jsonrpc: "2.0", id: 1, method: "resources/list" }),
      JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "other", arguments: {} } }),
      JSON.stringify({ jsonrpc: "2.0", id: 3, method: "ping" }),
      "",
    ].join("\n"));
    assert.equal(replies[0]?.error?.code, -32601);
    assert.equal(replies[1]?.error?.code, -32602);
    assert.deepEqual(replies[2], { jsonrpc: "2.0", id: 3, result: {} } as Reply);
    assert.equal(core.requests.length, 0);
  } finally {
    core.server.close();
  }
});

// --- Очередь вызовов и уход ядра (LUNA-49)

/** Мост дочерним процессом с открытым stdin: тест пишет строки по ходу и закрывает его сам. */
function liveBridge(socketPath: string) {
  const child = spawn(process.execPath, [BRIDGE_PATH, socketPath, "run-1"], { stdio: ["pipe", "pipe", "pipe"] });
  const replies: Reply[] = [];
  createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => replies.push(JSON.parse(line) as Reply));
  const exit = new Promise<number | null>((resolve) => child.once("close", resolve));
  return { child, replies, exit };
}

const toolsCall = (id: number, file: string) =>
  JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name: "approve", arguments: { tool_name: "Write", input: { file_path: file }, tool_use_id: `toolu_${id}` } } });

test("мост: два tools/call подряд — второе соединение с ядром только после ответа на первое, ответы CLI в порядке вызовов", async () => {
  // Ядро, которое отвечает, только когда скажет тест.
  const waiting: { request: BridgeRequest; answer: (decision: unknown) => void }[] = [];
  let connections = 0;
  const path = join(mkdtempSync(join(tmpdir(), "luna-b-")), "core.sock");
  const server = createServer((socket) => {
    connections += 1;
    socket.setEncoding("utf8");
    createInterface({ input: socket }).once("line", (line) => {
      waiting.push({ request: JSON.parse(line) as BridgeRequest, answer: (decision) => socket.end(`${JSON.stringify(decision)}\n`) });
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  try {
    const bridge = liveBridge(path);
    // Обе строки — одной записью, без паузы между ними.
    bridge.child.stdin.write(`${toolsCall(1, "/a.txt")}\n${toolsCall(2, "/b.txt")}\n`);
    await until(() => waiting.length === 1, "первого вызова в ядре");
    await quietPeriod();
    assert.equal(connections, 1, "второй вызов ждёт ответа на первый");
    assert.equal(bridge.replies.length, 0);

    waiting[0]?.answer({ behavior: "deny", message: "первый" });
    await until(() => waiting.length === 2, "второго вызова в ядре");
    assert.equal(connections, 2);
    assert.deepEqual(waiting.map(({ request }) => request.call.tool_use_id), ["toolu_1", "toolu_2"]);
    waiting[1]?.answer({ behavior: "allow", updatedInput: { file_path: "/b.txt" } });

    await until(() => bridge.replies.length === 2, "двух ответов CLI");
    assert.deepEqual(bridge.replies.map((reply) => reply.id), [1, 2]);
    assert.deepEqual(decisionOf(bridge.replies[0]), { behavior: "deny", message: "первый" });
    assert.deepEqual(decisionOf(bridge.replies[1]), { behavior: "allow", updatedInput: { file_path: "/b.txt" } });
    bridge.child.stdin.end();
    assert.equal(await bridge.exit, 0);
  } finally {
    server.close();
  }
});

test("мост: ядро закрыло сокет, пока мост ждёт, — CLI получает deny «Luna недоступна…»; после закрытия stdin мост выходит с кодом 0 быстрее 1 с", async () => {
  const path = join(mkdtempSync(join(tmpdir(), "luna-b-")), "core.sock");
  let received = false;
  const server = createServer((socket) => {
    createInterface({ input: socket }).once("line", () => {
      received = true;
      // Ядро уходит, не ответив: сервер закрыт, соединение оборвано, файла сокета нет.
      server.close();
      socket.destroy();
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  const bridge = liveBridge(path);
  bridge.child.stdin.write(`${toolsCall(1, "/a.txt")}\n`);
  await until(() => bridge.replies.length === 1, "ответа CLI");
  assert.ok(received);
  const first = decisionOf(bridge.replies[0]);
  assert.equal(first.behavior, "deny");
  assert.match(String(first.message), /^Luna недоступна: /);

  // Следующий вызов идёт в пустоту — тоже отказ, а не зависание.
  bridge.child.stdin.write(`${toolsCall(2, "/b.txt")}\n`);
  await until(() => bridge.replies.length === 2, "второго ответа CLI");
  assert.equal(decisionOf(bridge.replies[1]).behavior, "deny");

  const closedAt = Date.now();
  bridge.child.stdin.end();
  assert.equal(await bridge.exit, 0);
  assert.ok(Date.now() - closedAt < 1000, `мост выходил ${Date.now() - closedAt} мс`);
});
