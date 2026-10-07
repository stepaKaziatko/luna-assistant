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
