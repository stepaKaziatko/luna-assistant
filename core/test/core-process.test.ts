import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, openHistory } from "../src/tasks/history.ts";

const MAIN = fileURLToPath(new URL("../src/main.ts", import.meta.url));

// Упавшая проверка не должна оставлять ядро живым: иначе прогон тестов зависает, а не падает.
const cores: ReturnType<typeof spawn>[] = [];
after(() => {
  for (const core of cores) if (core.exitCode === null && core.signalCode === null) core.kill("SIGKILL");
});

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
  cores.push(child);
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
  seed?.save({ id: "old", threadId: "old", prompt: "вчерашний", status: "done", executor: "claude-code", result: "ответ", createdAt: 1, finishedAt: 2 });
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

test("task.submit с followUpOf: InvalidParams с context, executor и для неизвестной задачи; уточнение уходит с --resume", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const success = fileURLToPath(new URL("./fixtures/claude-code/success.jsonl", import.meta.url));
  // Подставной исполнитель: каждый запуск дописывает argv в файл и отдаёт записанный поток.
  const claude = join(dir, "claude");
  writeFileSync(claude, `#!/bin/sh\necho "$*" >> "${dir}/argv"\ncat > /dev/null\ncat "${success}"\n`);
  chmodSync(claude, 0o755);
  const core = startCore({ LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude });
  await core.request("core.hello");

  const done = core.waitFor((message) => message.method === "task.done");
  const first = (await core.request("task.submit", { prompt: "сводка" })).result?.task as TaskInfo;
  assert.equal(first.threadId, first.id);
  const answered = (await done).params?.task;
  assert.ok(answered?.sessionId);

  const invalid = async (params: object) => {
    const response = (await core.request("task.submit", params)) as Message & { error?: { code: number } };
    assert.equal(response.error?.code, -32602, JSON.stringify(params));
  };
  await invalid({ prompt: "ещё", followUpOf: first.id, context: { url: "https://example.com" } });
  await invalid({ prompt: "ещё", followUpOf: first.id, executor: "claude-code" });
  await invalid({ prompt: "ещё", followUpOf: "missing" });
  await invalid({ prompt: "ещё", followUpOf: 42 });

  const followUpDone = core.waitFor((message) => message.method === "task.done" && message.params?.task.id !== first.id);
  const followUp = (await core.request("task.submit", { prompt: "ещё", followUpOf: first.id })).result?.task as TaskInfo;
  assert.equal(followUp.threadId, first.id);
  assert.equal((await followUpDone).params?.task.threadId, first.id);
  // Каждый запуск начинается с -p; системный промпт внутри argv многострочный.
  const argv = readFileSync(join(dir, "argv"), "utf8").trimEnd().split(/^(?=-p )/m);
  assert.equal(argv.length, 2);
  assert.ok(!argv[0]?.includes("--resume"));
  assert.ok(argv[1]?.trimEnd().endsWith(`--resume ${answered.sessionId}`), argv[1]);
  assert.equal(await core.stop(), 0);
});

test("уточнение с потерянной сессией: ядро само отправляет переписку заново, задача завершается без ошибки", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const fixtures = new URL("./fixtures/claude-code/", import.meta.url);
  const success = fileURLToPath(new URL("success.jsonl", fixtures));
  const notFound = fileURLToPath(new URL("session-not-found.jsonl", fixtures));
  // Подставной исполнитель: stdin каждого запуска — в файл по номеру; с --resume сессии «нет».
  const claude = join(dir, "claude");
  writeFileSync(
    claude,
    [
      "#!/bin/sh",
      `n=$(( $(cat "${dir}/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${dir}/count"`,
      `cat > "${dir}/stdin-$n"`,
      `case "$*" in *--resume*) echo resume >> "${dir}/calls"; cat "${notFound}"; exit 1;; esac`,
      `echo new >> "${dir}/calls"`,
      `cat "${success}"`,
      "",
    ].join("\n"),
  );
  chmodSync(claude, 0o755);
  const core = startCore({ LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude });
  await core.request("core.hello");

  const done = core.waitFor((message) => message.method === "task.done");
  const first = (await core.request("task.submit", { prompt: "сводка", context: { url: "https://example.com" } })).result?.task as TaskInfo;
  assert.ok((await done).params?.task.result);

  const followUpDone = core.waitFor((message) => message.method === "task.done" && message.params?.task.id !== first.id);
  const followUp = (await core.request("task.submit", { prompt: "а подробнее?", followUpOf: first.id })).result?.task as TaskInfo;
  const finished = (await followUpDone).params?.task;
  assert.equal(finished?.id, followUp.id);
  assert.equal(finished?.status, "done");

  assert.deepEqual(readFileSync(join(dir, "calls"), "utf8").trim().split("\n"), ["new", "resume", "new"]);
  const resent = readFileSync(join(dir, "stdin-3"), "utf8");
  assert.ok(resent.startsWith("<context>\nurl: https://example.com\n</context>\n\n<history>\n<question>\nсводка\n</question>"), resent);
  assert.ok(resent.endsWith("</history>\n\n<task>\nа подробнее?\n</task>"), resent);
  const methods = core.lines.map((line) => (JSON.parse(line) as Message).method);
  assert.equal(methods.includes("task.failed"), false);
  assert.ok(
    core.lines.some((line) => (JSON.parse(line) as Message).params?.task.progress === "разговор не сохранился, отправляю переписку заново…"),
  );
  assert.equal(await core.stop(), 0);
});
