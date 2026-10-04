import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, openHistory, type StoredTask, type TaskHistory } from "../src/tasks/history.ts";
import { TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun, quietPeriod, until } from "./support/wait.ts";

const quiet = () => {};

function dataDir(): string {
  return mkdtempSync(join(tmpdir(), "luna-data-"));
}

/** Запуск ядра на каталоге данных: история открывается, как в main.ts, и отдаётся менеджеру. */
async function start(dir: string, maxConcurrent = 3) {
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history, "история открылась");
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    maxConcurrent,
    history,
    emit: (event, task) => events.push({ event, task }),
  });
  return { history, executor, events, manager };
}

function stored(id: string, createdAt: number, status: TaskInfo["status"] = "done"): TaskInfo {
  return { id, threadId: id, prompt: `запрос ${id}`, status, executor: "claude-code", createdAt, finishedAt: createdAt + 1 };
}

/** Подменённое хранилище: считает записи, по желанию бросает на каждой. */
class FakeHistory implements TaskHistory {
  readonly saves: TaskInfo[] = [];
  private readonly failing: boolean;

  constructor(failing = false) {
    this.failing = failing;
  }

  save(task: TaskInfo): void {
    if (this.failing) throw new Error("database or disk is full");
    this.saves.push({ ...task });
  }
  recent(): StoredTask[] {
    return [];
  }
  get(): StoredTask | undefined {
    return undefined;
  }
  thread(): StoredTask[] {
    return [];
  }
  close(): void {}
}

test("выполненная, упавшая и отменённая задачи переживают перезапуск", async () => {
  const dir = dataDir();
  const first = await start(dir);
  const done = first.manager.submit({ prompt: "сводка", context: { url: "https://github.com/o/r", selection: "текст" } });
  const failed = first.manager.submit({ prompt: "ошибка" });
  const cancelled = first.manager.submit({ prompt: "отмена" });
  await until(() => first.executor.runs.length === 3, "запуска трёх задач");
  // Запуски параллельны и могут прийти в любом порядке — ищем по рабочей директории.
  const runOf = (id: string) => {
    const run = first.executor.runs.find((candidate) => candidate.request.cwd.endsWith(id));
    assert.ok(run, `запуск задачи ${id}`);
    return run;
  };
  runOf(done.id).push({ type: "session", sessionId: "s1" });
  runOf(done.id).push({ type: "progress", text: "читает README.md" });
  runOf(done.id).push({ type: "done", result: "готово" });
  runOf(failed.id).push({ type: "failed", error: { kind: "auth", message: "Not logged in" } });
  first.manager.cancel(cancelled.id);
  const status = (id: string) => first.history.get(id)?.task.status;
  await until(
    () => status(done.id) === "done" && status(failed.id) === "failed" && status(cancelled.id) === "cancelled",
    "записи итогов трёх задач",
  );
  const before = first.manager.list();
  first.history.close();

  const second = await start(dir);
  const after = second.manager.list();
  assert.deepEqual(after, before);

  const restored = after.find((task) => task.id === done.id);
  assert.equal(restored?.status, "done");
  assert.equal(restored?.result, "готово");
  assert.equal(restored?.sessionId, "s1");
  assert.deepEqual(restored?.context, { url: "https://github.com/o/r", selection: "текст" });
  assert.equal(restored?.createdAt, done.createdAt);
  assert.ok(restored?.finishedAt);
  assert.equal("progress" in (restored ?? {}), false);
  assert.deepEqual(after.find((task) => task.id === failed.id)?.error, { kind: "auth", message: "Not logged in" });
  assert.equal(after.find((task) => task.id === cancelled.id)?.status, "cancelled");

  // Рабочая директория хранится, но в протокол не выходит.
  const row = second.history.recent(10).find((entry) => entry.task.id === done.id);
  assert.equal(row?.workdir, runOf(done.id).request.cwd);
  assert.equal("workdir" in (restored ?? {}), false);
});

test("задачи running и queued брошенного менеджера после старта — failed с текстом о закрытии", async () => {
  const dir = dataDir();
  const first = await start(dir, 1);
  const running = first.manager.submit({ prompt: "долгая" });
  const queued = first.manager.submit({ prompt: "в очереди" });
  // Исполнитель запускается после записи статуса running.
  await nextRun(first.executor, 0);
  assert.equal(first.history.get(running.id)?.task.status, "running");

  const second = await start(dir);
  for (const id of [running.id, queued.id]) {
    const task = second.manager.list().find((candidate) => candidate.id === id);
    assert.equal(task?.status, "failed");
    assert.deepEqual(task?.error, { kind: "unknown", message: INTERRUPTED_MESSAGE });
    assert.ok(task?.finishedAt);
  }
});

test("выход из Luna: выполняющаяся задача записывается прерванной, а не отменённой", async () => {
  const dir = dataDir();
  const first = await start(dir, 1);
  const running = first.manager.submit({ prompt: "долгая" });
  const queued = first.manager.submit({ prompt: "в очереди" });
  const run = await nextRun(first.executor, 0);

  first.manager.shutdown();
  await quietPeriod();
  assert.equal(run.request.signal.aborted, true);
  assert.equal(first.executor.runs.length, 1, "задача из очереди не запускается");
  assert.deepEqual(first.events.map((entry) => entry.event), ["task.started"]);
  first.history.close();

  const second = await start(dir);
  for (const id of [running.id, queued.id]) {
    const task = second.manager.list().find((candidate) => candidate.id === id);
    assert.equal(task?.status, "failed");
    assert.equal(task?.error?.message, INTERRUPTED_MESSAGE);
  }
});

test("хранится 1000 новых задач, list() отдаёт 200 от новых к старым", async () => {
  const dir = dataDir();
  const seed = await openHistory(dir, { log: quiet });
  for (let index = 0; index < 1005; index += 1) seed?.save(stored(`t${index}`, 1_000 + index));
  seed?.close();

  const { history, manager } = await start(dir);
  const kept = history.recent(2000);
  assert.equal(kept.length, 1000);
  assert.equal(Math.min(...kept.map((entry) => entry.task.createdAt)), 1_005);

  const listed = manager.list();
  assert.equal(listed.length, 200);
  assert.equal(listed[0]?.createdAt, 2_004);
  assert.equal(listed.at(-1)?.createdAt, 1_805);
  assert.deepEqual(listed.map((task) => task.createdAt), [...listed.map((task) => task.createdAt)].sort((a, b) => b - a));
});

test("активные задачи попадают в list() всегда, всего не больше 200", async () => {
  const dir = dataDir();
  const seed = await openHistory(dir, { log: quiet });
  // Завершённые новее активных: иначе их не вытеснить.
  const future = Date.now() + 1_000_000;
  for (let index = 0; index < 300; index += 1) seed?.save(stored(`t${index}`, future + index));
  seed?.close();

  const { manager } = await start(dir, 1);
  // Задача активна с момента отправки: ждать запуска не нужно.
  const active = [manager.submit({ prompt: "1" }), manager.submit({ prompt: "2" }), manager.submit({ prompt: "3" })];

  const listed = manager.list();
  assert.equal(listed.length, 200);
  for (const task of active) assert.ok(listed.some((candidate) => candidate.id === task.id), task.prompt);
  assert.equal(listed[0]?.createdAt, future + 299);
});

test("повреждённый history.db откладывается, ядро работает с новым", async () => {
  const dir = dataDir();
  const garbage = "это не база SQLite\n".repeat(100);
  writeFileSync(join(dir, "history.db"), garbage);

  const logs: string[] = [];
  const history = await openHistory(dir, { log: (message) => logs.push(message) });
  assert.ok(history);
  const broken = readdirSync(dir).filter((name) => /^history\.broken-\d+\.db$/.test(name));
  assert.equal(broken.length, 1);
  assert.equal(readFileSync(join(dir, broken[0] ?? ""), "utf8"), garbage);
  assert.ok(logs.some((message) => message.includes("history.db")));

  const executor = new ManualExecutor();
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    history,
    emit: quiet,
  });
  const task = manager.submit({ prompt: "после сбоя" });
  (await nextRun(executor, 0)).push({ type: "done", result: "ok" });
  await until(() => history.get(task.id)?.task.status === "done", "записи итога задачи");
  history.close();

  const next = await start(dir);
  assert.equal(next.manager.list().find((candidate) => candidate.id === task.id)?.result, "ok");
});

test("history.db, занятый другим процессом, не считается повреждённым", async () => {
  const dir = dataDir();
  const seed = await openHistory(dir, { log: quiet });
  seed?.save(stored("keep", 1));
  seed?.close();

  const { DatabaseSync } = await import("node:sqlite");
  const holder = new DatabaseSync(join(dir, "history.db"));
  holder.exec("BEGIN EXCLUSIVE");
  try {
    const history = await openHistory(dir, { log: quiet });
    assert.equal(history, undefined);
    assert.deepEqual(readdirSync(dir).filter((name) => name.startsWith("history.broken-")), []);
  } finally {
    holder.exec("ROLLBACK");
    holder.close();
  }
  const reopened = await openHistory(dir, { log: quiet });
  assert.deepEqual(reopened?.recent(10).map((entry) => entry.task.id), ["keep"]);
});

test("сбой записи не мешает задаче: она выполняется, видна в list(), ошибка — в stderr", async (t) => {
  const stderr: string[] = [];
  t.mock.method(process.stderr, "write", (chunk: string | Uint8Array) => {
    stderr.push(String(chunk));
    return true;
  });
  const executor = new ManualExecutor();
  const events: TaskEventName[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dataDir(), "tasks"),
    history: new FakeHistory(true),
    emit: (event) => events.push(event),
  });
  const task = manager.submit({ prompt: "x" });
  (await nextRun(executor, 0)).push({ type: "done", result: "готово" });
  await until(() => events.includes("task.done"), "завершения задачи");

  assert.deepEqual(events, ["task.started", "task.done"]);
  assert.equal(manager.list().find((candidate) => candidate.id === task.id)?.result, "готово");
  assert.ok(stderr.some((line) => line.includes("database or disk is full")));
});

test("прогресс исполнителя не пишется на диск", async () => {
  const history = new FakeHistory();
  const executor = new ManualExecutor();
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dataDir(), "tasks"),
    history,
    emit: quiet,
  });
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  run.push({ type: "session", sessionId: "s1" });
  await until(() => history.saves.at(-1)?.sessionId === "s1", "записи сессии");
  const writes = history.saves.length;

  run.push({ type: "progress", text: "читает" });
  run.push({ type: "progress", text: "пишет" });
  await until(() => manager.list().find((candidate) => candidate.id === task.id)?.progress === "пишет", "прогресса");
  assert.equal(history.saves.length, writes);

  run.push({ type: "done", result: "ok" });
  await until(() => history.saves.at(-1)?.status === "done", "записи итога");
  assert.deepEqual(history.saves.map((task) => task.status), ["queued", "running", "running", "done"]);
  assert.ok(history.saves.every((task) => task.progress === undefined));
});
