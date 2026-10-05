import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun, quietPeriod, until } from "./support/wait.ts";

function setup(maxConcurrent = 3) {
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: mkdtempSync(join(tmpdir(), "luna-tasks-")),
    maxConcurrent,
    emit: (event, task) => events.push({ event, task }),
  });
  return { executor, events, manager };
}

const eventNames = (events: { event: TaskEventName }[]) => events.map((entry) => entry.event);

test("задача проходит путь queued → running → done", async () => {
  const { executor, events, manager } = setup();
  const submitted = manager.submit({ prompt: "сводка", context: { url: "https://github.com/o/r" } });
  assert.equal(submitted.status, "queued");

  const run = await nextRun(executor, 0);
  assert.equal(run.request.prompt, "<context>\nurl: https://github.com/o/r\n</context>\n\n<task>\nсводка\n</task>");
  assert.ok(run.request.cwd.endsWith(submitted.id));

  run.push({ type: "session", sessionId: "s1" });
  run.push({ type: "progress", text: "читает README.md" });
  run.push({ type: "done", result: "готово" });
  await until(() => eventNames(events).includes("task.done"), "завершения задачи");

  assert.deepEqual(eventNames(events), ["task.started", "task.progress", "task.done"]);
  assert.equal(events[1]?.task.progress, "читает README.md");
  const done = events[2]?.task;
  assert.equal(done?.status, "done");
  assert.equal(done?.result, "готово");
  assert.equal(done?.sessionId, "s1");
  assert.equal(done?.progress, undefined);
  assert.ok(done?.finishedAt);
});

test("параллельные задачи ограничены maxConcurrent, очередь продвигается", async () => {
  const { executor, manager } = setup(2);
  manager.submit({ prompt: "1" });
  manager.submit({ prompt: "2" });
  const third = manager.submit({ prompt: "3" });
  const first = await nextRun(executor, 0);
  await nextRun(executor, 1);

  await quietPeriod();
  assert.equal(executor.runs.length, 2);
  assert.equal(manager.list().find((task) => task.id === third.id)?.status, "queued");

  first.push({ type: "done", result: "ok" });
  await nextRun(executor, 2);
  assert.equal(manager.list().find((task) => task.id === third.id)?.status, "running");
});

test("ошибка исполнителя переводит задачу в failed", async () => {
  const { executor, events, manager } = setup();
  manager.submit({ prompt: "x" });
  (await nextRun(executor, 0)).push({ type: "failed", error: { kind: "auth", message: "Not logged in" } });
  await until(() => eventNames(events).includes("task.failed"), "ошибки задачи");

  const last = events.at(-1);
  assert.equal(last?.event, "task.failed");
  assert.deepEqual(last?.task.error, { kind: "auth", message: "Not logged in" });
});

test("отмена выполняющейся задачи прерывает исполнителя", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);

  assert.equal(manager.cancel(task.id), true);
  assert.equal(run.request.signal.aborted, true);
  await quietPeriod();
  assert.deepEqual(eventNames(events), ["task.started", "task.cancelled"]);
  assert.equal(manager.cancel(task.id), false);
});

test("отмена задачи в очереди: исполнитель не запускается", async () => {
  const { executor, events, manager } = setup(1);
  manager.submit({ prompt: "1" });
  const queued = manager.submit({ prompt: "2" });
  const run = await nextRun(executor, 0);

  manager.cancel(queued.id);
  run.push({ type: "done", result: "ok" });
  await until(() => eventNames(events).includes("task.done"), "завершения первой задачи");
  await quietPeriod();

  assert.equal(executor.runs.length, 1);
  assert.deepEqual(eventNames(events), ["task.started", "task.cancelled", "task.done"]);
});
