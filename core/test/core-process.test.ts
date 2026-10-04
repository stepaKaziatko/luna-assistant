import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, openHistory } from "../src/tasks/history.ts";

const MAIN = fileURLToPath(new URL("../src/main.ts", import.meta.url));

interface Message {
  id?: number;
  method?: string;
  result?: Record<string, unknown>;
  params?: { task: TaskInfo };
}

/** Ядро дочерним процессом, как его запускает оболочка: JSON-RPC построчно в stdio. */
function startCore(env: Record<string, string>) {
  const child = spawn(process.execPath, [MAIN], {
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stderr.resume();
  const lines: string[] = [];
  const waiters: { match: (message: Message) => boolean; resolve: (message: Message) => void }[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    lines.push(line);
    const message = JSON.parse(line) as Message;
    const index = waiters.findIndex((waiter) => waiter.match(message));
    if (index !== -1) waiters.splice(index, 1)[0]?.resolve(message);
  });
  const exited = new Promise<number | null>((resolve) => child.once("exit", resolve));
  let nextId = 1;

  const waitFor = (match: (message: Message) => boolean) =>
    new Promise<Message>((resolve) => waiters.push({ match, resolve }));
  const request = (method: string, params: unknown = {}) => {
    const id = nextId++;
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return waitFor((message) => message.id === id);
  };
  const stop = () => {
    child.stdin.end();
    return exited;
  };
  return { lines, request, waitFor, stop };
}

test("ядро с историей: stdout — только протокол, task.list отдаёт историю, выход прерывает задачу", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  // Подставной исполнитель, который не завершается сам.
  const claude = join(dir, "claude");
  writeFileSync(claude, "#!/bin/sh\nexec sleep 30\n");
  chmodSync(claude, 0o755);
  const env = { LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude };

  const seed = await openHistory(dir, { log: () => {} });
  seed?.save({ id: "old", prompt: "вчерашний", status: "done", executor: "claude-code", result: "ответ", createdAt: 1, finishedAt: 2 });
  seed?.close();

  const first = startCore(env);
  const hello = await first.request("core.hello");
  // Первая строка stdout — ответ на core.hello, а не диагностика.
  const firstLine = JSON.parse(first.lines[0] ?? "") as Message;
  assert.equal(firstLine.id, 1);
  assert.equal(typeof hello.result?.version, "string");

  const listed = (await first.request("task.list")).result?.tasks as TaskInfo[];
  assert.deepEqual(listed.map((task) => [task.id, task.result]), [["old", "ответ"]]);

  const started = first.waitFor((message) => message.method === "task.started");
  const submitted = (await first.request("task.submit", { prompt: "долгая" })).result?.task as TaskInfo;
  await started;
  assert.equal(await first.stop(), 0);
  for (const line of first.lines) assert.equal((JSON.parse(line) as { jsonrpc?: string }).jsonrpc, "2.0");

  const second = startCore(env);
  await second.request("core.hello");
  const after = (await second.request("task.list")).result?.tasks as TaskInfo[];
  const interrupted = after.find((task) => task.id === submitted.id);
  assert.equal(interrupted?.status, "failed");
  assert.deepEqual(interrupted?.error, { kind: "unknown", message: INTERRUPTED_MESSAGE });
  assert.equal(after.find((task) => task.id === "old")?.result, "ответ");
  assert.equal(await second.stop(), 0);
});
