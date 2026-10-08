import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
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

/** Сколько ждать сообщения ядра: подставной исполнитель отвечает за доли секунды, запас — на медленный раннер CI. */
const WAIT_TIMEOUT_MS = 10_000;

interface Waiter {
  match: (message: Message) => boolean;
  resolve: (message: Message) => void;
  reject: (error: Error) => void;
}

/** Ядро дочерним процессом, как его запускает оболочка: JSON-RPC построчно в stdio. */
function startCore(env: Record<string, string>) {
  const child = spawn(process.execPath, [MAIN], {
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  cores.push(child);
  // Хвост stderr — в сообщение об ошибке, если ядро умерло: по нему видно, почему.
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
    stderr = (stderr + chunk).slice(-2000);
  });
  // Запись в stdin умершего ядра — EPIPE; без обработчика он уронил бы весь прогон, а не тест.
  child.stdin.on("error", () => {});
  const lines: string[] = [];
  const waiters: Waiter[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    lines.push(line);
    const message = JSON.parse(line) as Message;
    const index = waiters.findIndex((waiter) => waiter.match(message));
    if (index !== -1) waiters.splice(index, 1)[0]?.resolve(message);
  });
  const exited = new Promise<number | null>((resolve) => child.once("exit", resolve));
  // «close» — после выхода и закрытия stdio: все строки stdout уже разобраны, ждать больше нечего.
  let closed: string | undefined;
  child.once("close", (code, signal) => {
    closed = `ядро завершилось (код ${code}, сигнал ${signal})${stderr ? `; stderr:\n${stderr}` : ""}`;
    for (const waiter of waiters.splice(0)) waiter.reject(new Error(closed));
  });
  let nextId = 1;

  // Ожидание обрывается ошибкой, если ядро умерло или сообщение не пришло вовремя: упавшее ядро роняет тест, а не вешает прогон.
  const waitFor = (match: (message: Message) => boolean, what = "сообщения ядра") => {
    const waiting = new Promise<Message>((resolve, reject) => {
      if (closed) return reject(new Error(`не дождались ${what}: ${closed}`));
      const timer = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index !== -1) waiters.splice(index, 1);
        reject(new Error(`не дождались ${what} за ${WAIT_TIMEOUT_MS} мс`));
      }, WAIT_TIMEOUT_MS);
      const waiter: Waiter = {
        match,
        resolve: (message) => {
          clearTimeout(timer);
          resolve(message);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(new Error(`не дождались ${what}: ${error.message}`));
        },
      };
      waiters.push(waiter);
    });
    // Ошибка достаётся тому, кто ждёт; ожидание, которое тест не успел дождаться, не роняет прогон «необработанным отказом».
    waiting.catch(() => {});
    return waiting;
  };
  const request = (method: string, params: unknown = {}) => {
    const id = nextId++;
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return waitFor((message) => message.id === id, `ответа на ${method}`);
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

/** Жив ли процесс: сигнал 0 ничего не шлёт, а только проверяет, есть ли такой pid. */
function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test("выход оболочки (EOF в stdin ядра): процесс исполнителя завершается, задача после перезапуска failed", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  // Подставной исполнитель пишет свой pid и висит: после выхода Luna он не должен остаться сиротой.
  const claude = join(dir, "claude");
  writeFileSync(claude, `#!/bin/sh\necho $$ > "${dir}/executor.pid"\nexec sleep 30\n`);
  chmodSync(claude, 0o755);
  const env = { LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude };

  const first = startCore(env);
  await first.request("core.hello");
  const started = first.waitFor((message) => message.method === "task.started");
  const submitted = (await first.request("task.submit", { prompt: "долгая" })).result?.task as TaskInfo;
  await started;
  // Запуск процесса и запись pid — отдельные шаги: ждём файл, а не угадываем.
  const pidFile = join(dir, "executor.pid");
  const deadline = Date.now() + WAIT_TIMEOUT_MS;
  while (!existsSync(pidFile) || readFileSync(pidFile, "utf8").trim() === "") {
    assert.ok(Date.now() < deadline, "исполнитель не записал свой pid");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const executorPid = Number(readFileSync(pidFile, "utf8").trim());
  assert.ok(isAlive(executorPid), "до выхода исполнитель должен работать");

  // Так выглядит выход Luna для ядра: оболочка закрыла его stdin.
  assert.equal(await first.stop(), 0);
  const killedBy = Date.now() + 5_000;
  while (isAlive(executorPid) && Date.now() < killedBy) await new Promise((resolve) => setTimeout(resolve, 50));
  const survived = isAlive(executorPid);
  if (survived) process.kill(executorPid, "SIGKILL");
  assert.ok(!survived, "исполнитель пережил выход ядра больше 5 с");

  const second = startCore(env);
  await second.request("core.hello");
  const after = (await second.request("task.list")).result?.tasks as TaskInfo[];
  const interrupted = after.find((task) => task.id === submitted.id);
  assert.equal(interrupted?.status, "failed");
  assert.deepEqual(interrupted?.error, { kind: "unknown", message: INTERRUPTED_MESSAGE });
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

  // Ждём и ошибку: сломанное ядро должно уронить тест проверкой статуса, а не подвесить прогон.
  const done = core.waitFor((message) => message.method === "task.done" || message.method === "task.failed");
  const first = (await core.request("task.submit", { prompt: "сводка" })).result?.task as TaskInfo;
  assert.equal(first.threadId, first.id);
  const answered = (await done).params?.task;
  assert.equal(answered?.status, "done", JSON.stringify(answered?.error));
  assert.ok(answered?.sessionId);

  const invalid = async (params: object) => {
    const response = (await core.request("task.submit", params)) as Message & { error?: { code: number } };
    assert.equal(response.error?.code, -32602, JSON.stringify(params));
  };
  await invalid({ prompt: "ещё", followUpOf: first.id, context: { url: "https://example.com" } });
  await invalid({ prompt: "ещё", followUpOf: first.id, executor: "claude-code" });
  await invalid({ prompt: "ещё", followUpOf: "missing" });
  await invalid({ prompt: "ещё", followUpOf: 42 });

  const followUpFinished = core.waitFor(
    (message) => (message.method === "task.done" || message.method === "task.failed") && message.params?.task.id !== first.id,
  );
  const followUp = (await core.request("task.submit", { prompt: "ещё", followUpOf: first.id })).result?.task as TaskInfo;
  assert.equal(followUp.threadId, first.id);
  const finished = (await followUpFinished).params?.task;
  assert.equal(finished?.status, "done", JSON.stringify(finished?.error));
  assert.equal(finished?.threadId, first.id);
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

  // Ждём и ошибку: сломанное выполнение первой задачи должно уронить тест проверкой статуса, а не подвесить прогон.
  const done = core.waitFor((message) => message.method === "task.done" || message.method === "task.failed");
  const first = (await core.request("task.submit", { prompt: "сводка", context: { url: "https://example.com" } })).result?.task as TaskInfo;
  const answered = (await done).params?.task;
  assert.equal(answered?.status, "done", JSON.stringify(answered?.error));
  assert.ok(answered?.result);

  // Ждём и ошибку: сломанная повторная отправка должна уронить тест, а не подвесить прогон.
  const followUpFinished = core.waitFor(
    (message) => (message.method === "task.done" || message.method === "task.failed") && message.params?.task.id !== first.id,
  );
  const followUp = (await core.request("task.submit", { prompt: "а подробнее?", followUpOf: first.id })).result?.task as TaskInfo;
  const finished = (await followUpFinished).params?.task;
  assert.equal(finished?.id, followUp.id);
  assert.equal(finished?.status, "done", JSON.stringify(finished?.error));

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

test("task.list с query, task.delete и task.clear через процесс ядра; удалённое не возвращается после перезапуска", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const success = fileURLToPath(new URL("./fixtures/claude-code/success.jsonl", import.meta.url));
  // Подставной исполнитель: запрос со словом «долгая» не завершается, остальные отдают записанный поток.
  const claude = join(dir, "claude");
  writeFileSync(claude, `#!/bin/sh\ncase "$(cat)" in *долгая*) exec sleep 30;; esac\ncat "${success}"\n`);
  chmodSync(claude, 0o755);
  const env = { LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude };
  const seed = await openHistory(dir, { log: () => {} });
  seed?.save({ id: "old", threadId: "old", prompt: "Сделай ПЕРЕВОД", status: "done", executor: "claude-code", result: "ok", createdAt: 1, finishedAt: 2 });
  seed?.save({ id: "keep", threadId: "keep", prompt: "погода", status: "done", executor: "claude-code", result: "ok", createdAt: 3, finishedAt: 4 });
  seed?.save({ id: "gone", threadId: "gone", prompt: "сводка", status: "done", executor: "claude-code", result: "ok", createdAt: 5, finishedAt: 6 });
  seed?.close();

  const core = startCore(env);
  await core.request("core.hello");
  const list = async (params?: unknown) => ((await core.request("task.list", params)).result?.tasks as TaskInfo[]).map((task) => task.id).sort();
  const errorCode = async (method: string, params: unknown) =>
    ((await core.request(method, params)) as Message & { error?: { code: number } }).error?.code;

  assert.deepEqual(await list({ query: "перевод" }), ["old"]);
  assert.deepEqual(await list({ query: "  " }), ["gone", "keep", "old"]);
  assert.deepEqual(await list({}), ["gone", "keep", "old"]);
  assert.equal(await errorCode("task.list", { query: 42 }), -32602);
  assert.equal(await errorCode("task.delete", {}), -32602);

  // Ждём и ошибку: сломанное ядро роняет тест, а не вешает его.
  const started = core.waitFor((message) => message.method === "task.started" || message.method === "task.failed");
  const running = (await core.request("task.submit", { prompt: "долгая" })).result?.task as TaskInfo;
  assert.equal((await started).method, "task.started");
  assert.equal(await errorCode("task.delete", { taskId: running.id }), -32602);

  assert.deepEqual((await core.request("task.delete", { taskId: "old" })).result, { deleted: ["old"] });
  assert.deepEqual((await core.request("task.delete", { taskId: "missing" })).result, { deleted: [] });
  assert.deepEqual(await list({ query: "перевод" }), []);
  assert.deepEqual(((await core.request("task.clear")).result?.deleted as string[]).sort(), ["gone", "keep"]);
  assert.deepEqual(await list(), [running.id]);
  assert.equal(await core.stop(), 0);

  const second = startCore(env);
  await second.request("core.hello");
  const after = (await second.request("task.list")).result?.tasks as TaskInfo[];
  assert.deepEqual(after.map((task) => [task.id, task.status]), [[running.id, "failed"]]);
  assert.equal(await second.stop(), 0);
});

test("task.submit с model: некорректные значения — InvalidParams, допустимые уходят в argv; в task.done — точная модель CLI", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const success = fileURLToPath(new URL("./fixtures/claude-code/success.jsonl", import.meta.url));
  const claude = join(dir, "claude");
  // Каждый запуск пишет argv построчно, между запусками — пустая строка-разделитель.
  writeFileSync(claude, `#!/bin/sh\nprintf '%s\\n' "$@" >> "${dir}/argv"\necho "---" >> "${dir}/argv"\ncat > /dev/null\ncat "${success}"\n`);
  chmodSync(claude, 0o755);
  const core = startCore({ LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude });
  await core.request("core.hello");

  const invalid = async (params: object) => {
    const response = (await core.request("task.submit", params)) as Message & { error?: { code: number; message: string } };
    assert.equal(response.error?.code, -32602, JSON.stringify(params));
    return response.error?.message;
  };
  for (const model of ["--x", "a b", "", "a\nb", "a".repeat(101), 42, null, ["sonnet"], "-sonnet", ".sonnet", "a;b", "a$(b)"]) {
    assert.equal(await invalid({ prompt: "привет", model }), "invalid model", JSON.stringify(model));
  }

  const accepted = async (model: string) => {
    const finished = core.waitFor(
      (message) => (message.method === "task.done" || message.method === "task.failed") && message.params?.task.prompt === model,
    );
    const response = (await core.request("task.submit", { prompt: model, model })) as Message & { error?: unknown };
    assert.equal(response.error, undefined, model);
    assert.equal((response.result?.task as TaskInfo).model, model);
    const task = (await finished).params?.task;
    assert.equal(task?.status, "done", JSON.stringify(task?.error));
    // Подставной CLI — как `success.jsonl`: init называет точную модель.
    assert.equal(task?.model, "claude-fable-5");
  };
  const long = `a${"b".repeat(99)}`;
  for (const model of ["sonnet", "claude-opus-4-8[1m]", long]) await accepted(model);

  // Некорректная модель с followUpOf — «invalid model» раньше любой другой проверки, в том числе для задачи, которой нет.
  for (const model of ["--x", "a b", "", "a".repeat(101)]) {
    assert.equal(await invalid({ prompt: "ещё", model, followUpOf: "missing" }), "invalid model", JSON.stringify(model));
  }
  // Допустимая модель с неизвестной задачей — отказ по задаче, а не по модели.
  assert.equal(await invalid({ prompt: "ещё", model: "sonnet", followUpOf: "missing" }), "task not found: missing");

  const runs = readFileSync(join(dir, "argv"), "utf8").split("---\n").filter((run) => run !== "");
  assert.equal(runs.length, 3);
  const models = runs.map((run) => {
    const argv = run.trimEnd().split("\n");
    return argv[argv.indexOf("--model") + 1];
  });
  assert.deepEqual([...models].sort(), ["claude-opus-4-8[1m]", long, "sonnet"].sort());

  // Уточнение: с model — переданная, без неё — точная модель продолжаемой задачи; context и executor по-прежнему нельзя.
  const submitFollowUp = async (params: object) => {
    const finished = core.waitFor((message) => message.method === "task.done" || message.method === "task.failed");
    const response = (await core.request("task.submit", params)) as Message & { result?: { task: TaskInfo }; error?: unknown };
    assert.equal(response.error, undefined, JSON.stringify(params));
    const task = (await finished).params?.task as TaskInfo;
    assert.equal(task.status, "done", JSON.stringify(task.error));
    return { submitted: response.result?.task as TaskInfo, task };
  };
  const base = (await submitFollowUp({ prompt: "основа", model: "opus" })).task;
  assert.equal(base.model, "claude-fable-5");
  await invalid({ prompt: "ещё", model: "haiku", followUpOf: base.id, context: { url: "https://example.com" } });
  await invalid({ prompt: "ещё", model: "haiku", followUpOf: base.id, executor: "claude-code" });

  const switched = await submitFollowUp({ prompt: "на другой", model: "haiku", followUpOf: base.id });
  assert.equal(switched.submitted.model, "haiku");
  assert.equal(switched.submitted.threadId, base.id);
  const inherited = await submitFollowUp({ prompt: "на той же", followUpOf: switched.task.id });
  assert.equal(inherited.submitted.model, "claude-fable-5");

  // Запуски идут по порядку: три задачи выше, затем основа, уточнение на haiku и уточнение без модели.
  const argvOf = (index: number) => {
    const run = readFileSync(join(dir, "argv"), "utf8").split("---\n").filter((entry) => entry !== "")[index];
    assert.ok(run, `запуск №${index}`);
    return run.trimEnd().split("\n");
  };
  const switchedArgv = argvOf(4);
  assert.deepEqual(switchedArgv.slice(switchedArgv.indexOf("--model"), switchedArgv.indexOf("--model") + 2), ["--model", "haiku"]);
  assert.equal(switchedArgv[switchedArgv.indexOf("--resume") + 1], base.sessionId);
  const inheritedArgv = argvOf(5);
  assert.equal(inheritedArgv[inheritedArgv.indexOf("--model") + 1], "claude-fable-5");
  assert.equal(inheritedArgv[inheritedArgv.indexOf("--resume") + 1], switched.task.sessionId);
  assert.equal(await core.stop(), 0);

  // Без модели в запросе флага нет (LUNA_CLAUDE_MODEL не задан).
  const plain = startCore({ LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude, LUNA_CLAUDE_MODEL: "" });
  await plain.request("core.hello");
  const done = plain.waitFor((message) => message.method === "task.done" || message.method === "task.failed");
  const task = ((await plain.request("task.submit", { prompt: "без модели" })).result?.task ?? {}) as TaskInfo;
  assert.equal("model" in task, false);
  assert.equal((await done).params?.task.status, "done");
  const last = readFileSync(join(dir, "argv"), "utf8").split("---\n").filter((run) => run !== "").at(-1) ?? "";
  assert.equal(last.includes("--model"), false);
  assert.equal(await plain.stop(), 0);
});

test("task.approve через процесс ядра: неверные params — InvalidParams; ответ на висящий запрос — {} и task.progress без approval; сокет убирается при выходе и чистится при старте", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  // Остаток сокета прежнего запуска: ядро должно убрать его при старте.
  writeFileSync(join(dir, "approvals-deadbeef.sock"), "");
  const socketFiles = () => readdirSync(dir).filter((name) => name.endsWith(".sock"));
  // Подставной исполнитель: вместо моста сам подключается к сокету ядра из --mcp-config, спрашивает
  // разрешение на Write и после ответа пишет решение в файл и завершает поток результатом.
  const script = join(dir, "claude.mjs");
  writeFileSync(
    script,
    `
import { createConnection } from "node:net";
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const argv = process.argv.slice(2);
const config = JSON.parse(argv[argv.indexOf("--mcp-config") + 1]);
const [, socketPath, runId] = config.mcpServers.luna.args;
process.stdin.resume();
process.stdout.write(JSON.stringify({ type: "system", subtype: "init", session_id: "s-approve", model: "claude-fable-5" }) + "\\n");
// Как настоящий CLI: строка с вызовом инструмента — до вопроса мосту.
process.stdout.write(JSON.stringify({ type: "assistant", session_id: "s-approve", message: { content: [{ type: "tool_use", id: "t1", name: "Write", input: { file_path: "hello.txt", content: "hi" } }] } }) + "\\n");
const socket = createConnection(socketPath);
socket.setEncoding("utf8");
createInterface({ input: socket }).once("line", (line) => {
  writeFileSync(${JSON.stringify(join(dir, "decision"))}, line + "\\n");
  socket.end();
  process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "записал", session_id: "s-approve" }) + "\\n");
  process.exit(0);
});
socket.write(JSON.stringify({ run: runId, call: { tool_name: "Write", input: { file_path: "hello.txt", content: "hi" }, tool_use_id: "t1" } }) + "\\n");
`,
  );
  const claude = join(dir, "claude");
  writeFileSync(claude, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
  chmodSync(claude, 0o755);
  const core = startCore({ LUNA_DATA_DIR: dir, LUNA_CLAUDE_BIN: claude });
  await core.request("core.hello");
  assert.equal(socketFiles().length, 1, "один сокет этого запуска; остаток прежнего удалён");
  assert.equal(existsSync(join(dir, "approvals-deadbeef.sock")), false);

  const errorCode = async (params: unknown) =>
    ((await core.request("task.approve", params)) as Message & { error?: { code: number } }).error?.code;
  assert.equal(await errorCode("нет"), -32602);
  assert.equal(await errorCode({}), -32602);
  assert.equal(await errorCode({ taskId: "missing", approvalId: "a", allow: true }), -32602);
  assert.equal(await errorCode({ taskId: "missing", approvalId: "a", allow: "yes" }), -32602);

  const needsApproval = core.waitFor((message) => message.method === "task.needs_approval" || message.method === "task.failed");
  const submitted = (await core.request("task.submit", { prompt: "создай файл" })).result?.task as TaskInfo;
  const waiting = (await needsApproval).params?.task;
  assert.equal(waiting?.status, "running", JSON.stringify(waiting?.error));
  assert.equal(waiting?.approval?.kind, "write");
  assert.ok(waiting?.approval?.target?.endsWith("hello.txt"), waiting?.approval?.target);
  assert.equal(await errorCode({ taskId: submitted.id, approvalId: "stale", allow: true }), -32602);
  assert.equal(await errorCode({ taskId: submitted.id, approvalId: waiting?.approval?.id, allow: 1 }), -32602);

  const progressed = core.waitFor((message) => message.method === "task.progress" && message.params?.task.id === submitted.id);
  const done = core.waitFor((message) => message.method === "task.done" || message.method === "task.failed");
  const response = await core.request("task.approve", { taskId: submitted.id, approvalId: waiting?.approval?.id, allow: true });
  assert.deepEqual(response.result, {});
  assert.equal((await progressed).params?.task.approval, undefined);
  const finished = (await done).params?.task;
  assert.equal(finished?.status, "done", JSON.stringify(finished?.error));
  assert.equal(finished?.approval, undefined);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "decision"), "utf8")), {
    behavior: "allow",
    updatedInput: { file_path: "hello.txt", content: "hi" },
  });

  assert.equal(await core.stop(), 0);
  assert.deepEqual(socketFiles(), [], "после выхода файла сокета нет");
});
