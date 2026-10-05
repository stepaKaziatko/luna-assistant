import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildArgs, ClaudeCodeExecutor } from "../src/executors/claude-code/adapter.ts";
import { ClaudeStreamParser } from "../src/executors/claude-code/stream.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { openHistory } from "../src/tasks/history.ts";
import { TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun, quietPeriod, until } from "./support/wait.ts";

const fixture = (name: string) => fileURLToPath(new URL(`./fixtures/claude-code/${name}`, import.meta.url));

function parseFixture(name: string): ExecutorEvent[] {
  const parser = new ClaudeStreamParser();
  return readFileSync(fixture(name), "utf8").split("\n").flatMap((line) => parser.push(line));
}

// --- Адаптер: --model из запроса и из options.model

test("buildArgs: --model из значения; без модели флага нет; --model перед --resume", () => {
  const withModel = buildArgs("RULES", "opus");
  assert.deepEqual(withModel.slice(-2), ["--model", "opus"]);
  assert.equal(buildArgs("RULES").includes("--model"), false);
  assert.equal(buildArgs("RULES", undefined, { sessionId: "s1" }).includes("--model"), false);

  const resumed = buildArgs("RULES", "opus", { sessionId: "s1" });
  assert.deepEqual(resumed.slice(-4), ["--model", "opus", "--resume", "s1"]);
});

/** Подменный `claude`: записывает argv в файл и отдаёт записанный поток. */
function fakeClaude(streamFixture: string): { binary: string; argv: () => string[] } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const binary = join(dir, "claude");
  writeFileSync(binary, `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\ncat > /dev/null\ncat "${fixture(streamFixture)}"\n`);
  chmodSync(binary, 0o755);
  return { binary, argv: () => readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n") };
}

async function runExecutor(executor: ClaudeCodeExecutor, model?: string): Promise<ExecutorEvent[]> {
  const events: ExecutorEvent[] = [];
  const request = { prompt: "<task>\nпривет\n</task>", formatRules: "RULES", cwd: tmpdir(), signal: new AbortController().signal };
  for await (const event of executor.run(model === undefined ? request : { ...request, model })) events.push(event);
  return events;
}

const modelArg = (argv: string[]) => argv[argv.indexOf("--model") + 1];

test("адаптер: модель запроса главнее options.model; options.model — запасное значение; без обеих флага нет", async () => {
  const both = fakeClaude("success.jsonl");
  const events = await runExecutor(new ClaudeCodeExecutor({ binary: both.binary, model: "haiku" }), "opus");
  assert.deepEqual(events.find((event) => event.type === "model"), { type: "model", model: "claude-fable-5" });
  assert.equal(modelArg(both.argv()), "opus");
  assert.equal(both.argv().filter((arg) => arg === "--model").length, 1);

  const fallback = fakeClaude("success.jsonl");
  await runExecutor(new ClaudeCodeExecutor({ binary: fallback.binary, model: "haiku" }));
  assert.equal(modelArg(fallback.argv()), "haiku");

  const neither = fakeClaude("success.jsonl");
  await runExecutor(new ClaudeCodeExecutor({ binary: neither.binary }));
  assert.equal(neither.argv().includes("--model"), false);
});

// --- Парсер: событие model

test("парсер: model из init идёт сразу после session; из not-logged-in — с суффиксом [1m]", () => {
  const events = parseFixture("not-logged-in.jsonl");
  assert.deepEqual(events.slice(0, 2), [
    { type: "session", sessionId: "eb15cb2f-ccc7-424f-bb48-f169e3cbcf71" },
    { type: "model", model: "claude-opus-4-8[1m]" },
  ]);
  assert.equal(events.filter((event) => event.type === "model").length, 1);
  assert.deepEqual(parseFixture("resume-success.jsonl").filter((event) => event.type === "model"), [
    { type: "model", model: "claude-sonnet-4-6" },
  ]);
});

test("парсер: пустая модель, <synthetic>, нестрока и init без model событий model не дают", () => {
  const init = (model: unknown) => JSON.stringify({ type: "system", subtype: "init", ...(model === undefined ? {} : { model }) });
  for (const model of ["<synthetic>", "", "  ", 42, null, undefined]) {
    assert.deepEqual(new ClaudeStreamParser().push(init(model)), [], String(model));
  }
  assert.deepEqual(new ClaudeStreamParser().push(init("sonnet")), [{ type: "model", model: "sonnet" }]);
});

test("парсер: модель только из init — assistant-сообщения и прочие system-строки её не дают", () => {
  const parser = new ClaudeStreamParser();
  const assistant = { type: "assistant", message: { model: "claude-sonnet-4-6", content: [{ type: "text", text: "x" }] } };
  assert.deepEqual(parser.push(JSON.stringify(assistant)), [{ type: "progress", text: "пишет ответ…" }]);
  assert.deepEqual(parser.push(JSON.stringify({ type: "system", subtype: "status", model: "claude-sonnet-4-6" })), []);
});

test("несуществующая модель (invalid-model.jsonl): model с этим именем, затем failed с текстом CLI, вид unknown", () => {
  const events = parseFixture("invalid-model.jsonl");
  assert.equal(events[0]?.type, "session");
  assert.deepEqual(events[1], { type: "model", model: "no-such-model-x" });
  // Служебное сообщение с model "<synthetic>" второго события model не даёт.
  assert.equal(events.filter((event) => event.type === "model").length, 1);
  const last = events.at(-1);
  assert.equal(last?.type, "failed");
  if (last?.type !== "failed") return;
  assert.equal(last.error.kind, "unknown");
  assert.match(last.error.message, /issue with the selected model/);
  assert.match(last.error.message, /no-such-model-x/);
});

// --- Менеджер

function setup(history?: Awaited<ReturnType<typeof openHistory>>) {
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: mkdtempSync(join(tmpdir(), "luna-tasks-")),
    ...(history ? { history } : {}),
    emit: (event, task) => events.push({ event, task }),
  });
  return { executor, events, manager };
}

test("менеджер: выбранная модель — в ответе submit и в запросе исполнителя; точная модель из события заменяет её в task.done", async () => {
  const { executor, events, manager } = setup();
  const submitted = manager.submit({ prompt: "x", model: "sonnet" });
  assert.equal(submitted.model, "sonnet");

  const run = await nextRun(executor, 0);
  assert.equal(run.request.model, "sonnet");
  // До события исполнителя в снимке — выбранное значение.
  run.push({ type: "progress", text: "читает" });
  await until(() => events.some((entry) => entry.event === "task.progress"), "прогресса");
  assert.equal(events.find((entry) => entry.event === "task.progress")?.task.model, "sonnet");

  run.push({ type: "model", model: "claude-sonnet-4-6" });
  run.push({ type: "done", result: "ok" });
  await until(() => events.some((entry) => entry.event === "task.done"), "завершения");
  // Событие model отдельного task.progress не шлёт.
  assert.deepEqual(events.map((entry) => entry.event), ["task.started", "task.progress", "task.done"]);
  assert.equal(events.at(-1)?.task.model, "claude-sonnet-4-6");
  assert.equal(manager.list()[0]?.model, "claude-sonnet-4-6");
});

test("менеджер: без выбора request.model не задан, info.model появляется после события model", async () => {
  const { executor, events, manager } = setup();
  const submitted = manager.submit({ prompt: "x" });
  assert.equal("model" in submitted, false);

  const run = await nextRun(executor, 0);
  assert.equal("model" in run.request, false);
  run.push({ type: "model", model: "claude-fable-5" });
  run.push({ type: "done", result: "ok" });
  await until(() => events.some((entry) => entry.event === "task.done"), "завершения");
  assert.equal(events.at(-1)?.task.model, "claude-fable-5");
});

test("менеджер: событие model после отмены info.model не меняет", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x", model: "opus" });
  const run = await nextRun(executor, 0);
  manager.cancel(task.id);
  run.push({ type: "model", model: "claude-opus-4-8" });
  await quietPeriod();
  assert.equal(events.at(-1)?.event, "task.cancelled");
  assert.equal(manager.list()[0]?.model, "opus");
});

test("менеджер: повторная отправка переписки получает выбор, а не точную модель исполнителя", async () => {
  const { executor, events, manager } = setup();
  const first = manager.submit({ prompt: "1" });
  const firstRun = await nextRun(executor, 0);
  firstRun.push({ type: "session", sessionId: "s1" });
  firstRun.push({ type: "done", result: "ответ 1" });
  await until(() => events.some((entry) => entry.event === "task.done"), "первой задачи");

  // Менеджер принимает model и с followUpOf: запрет — на уровне протокола (main.ts) до LUNA-36.
  const second = manager.submit({ prompt: "2", followUpOf: first.id, model: "sonnet" });
  const run = await nextRun(executor, 1);
  assert.equal(run.request.model, "sonnet");
  assert.deepEqual(run.request.resume, { sessionId: "s1" });
  run.push({ type: "model", model: "claude-sonnet-4-6" });
  run.push({ type: "failed", error: { kind: "session_not_found", message: "No conversation found" } });

  const resend = await nextRun(executor, 2);
  assert.equal(resend.request.resume, undefined);
  assert.equal(resend.request.model, "sonnet");
  resend.push({ type: "done", result: "ответ 2" });
  await until(() => manager.list().find((task) => task.id === second.id)?.status === "done", "уточнения");
});

// --- История

test("история: модель пишется и читается после переоткрытия history.db; у задачи без модели поля нет", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const history = await openHistory(dir, { log: () => {} });
  assert.ok(history);
  const { executor, events, manager } = setup(history);
  const withModel = manager.submit({ prompt: "с моделью", model: "opus" });
  const without = manager.submit({ prompt: "без модели" });
  const runs = await Promise.all([nextRun(executor, 0), nextRun(executor, 1)]);
  const runOf = (id: string) => runs.find((run) => run.request.cwd.endsWith(id));
  runOf(withModel.id)?.push({ type: "model", model: "claude-opus-4-8[1m]" });
  runOf(withModel.id)?.push({ type: "done", result: "ok" });
  runOf(without.id)?.push({ type: "done", result: "ok" });
  await until(() => events.filter((entry) => entry.event === "task.done").length === 2, "двух задач");
  history.close();

  const reopened = await openHistory(dir, { log: () => {} });
  assert.ok(reopened);
  assert.equal(reopened.get(withModel.id)?.task.model, "claude-opus-4-8[1m]");
  assert.equal("model" in (reopened.get(without.id)?.task ?? {}), false);
  reopened.close();
});

test("история: версии 1 и 2 мигрируют в 3, прежние задачи читаются без model, остальное цело", async () => {
  const { DatabaseSync } = await import("node:sqlite");
  for (const version of [1, 2]) {
    const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
    const old = new DatabaseSync(join(dir, "history.db"));
    old.exec(`
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL, executor TEXT NOT NULL,
        result TEXT, error TEXT, session_id TEXT, created_at INTEGER NOT NULL, finished_at INTEGER, workdir TEXT
        ${version === 2 ? ", thread_id TEXT" : ""}
      );
      PRAGMA user_version = ${version};
      INSERT INTO tasks (id, prompt, status, executor, result, session_id, created_at, finished_at, workdir)
        VALUES ('a', 'первая', 'done', 'claude-code', 'ответ', 'sa', 1, 2, '/tmp/luna/a');
      ${version === 2 ? "UPDATE tasks SET thread_id = id;" : ""}
    `);
    old.close();

    const history = await openHistory(dir, { log: () => {} });
    assert.ok(history, `версия ${version}`);
    const task = history.get("a");
    assert.deepEqual(task?.task, {
      id: "a", threadId: "a", prompt: "первая", status: "done", executor: "claude-code",
      result: "ответ", sessionId: "sa", createdAt: 1, finishedAt: 2,
    });
    assert.equal(task?.workdir, "/tmp/luna/a");
    // Новая запись с моделью ложится в мигрированную таблицу.
    history.save({ ...(task?.task as TaskInfo), model: "sonnet" });
    assert.equal(history.get("a")?.task.model, "sonnet");
    history.close();

    const check = new DatabaseSync(join(dir, "history.db"));
    assert.deepEqual({ ...(check.prepare("PRAGMA user_version").get() as object) }, { user_version: 3 });
    check.close();

    // Версия 3 открывается прежним путём.
    const again = await openHistory(dir, { log: () => {} });
    assert.equal(again?.get("a")?.task.model, "sonnet");
    again?.close();
  }
});
