import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";

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

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

test("задача проходит путь queued → running → done", async () => {
  const { executor, events, manager } = setup();
  const submitted = manager.submit({ prompt: "сводка", context: { url: "https://github.com/o/r" } });
  assert.equal(submitted.status, "queued");
  await settle();

  const run = executor.runs[0];
  assert.ok(run);
  assert.equal(run.request.prompt, "<context>\nurl: https://github.com/o/r\n</context>\n\n<task>\nсводка\n</task>");
  assert.ok(run.request.cwd.endsWith(submitted.id));

  run.push({ type: "session", sessionId: "s1" });
  run.push({ type: "progress", text: "читает README.md" });
  run.push({ type: "done", result: "готово" });
  await settle();

  assert.deepEqual(events.map((entry) => entry.event), ["task.started", "task.progress", "task.done"]);
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
  await settle();

  assert.equal(executor.runs.length, 2);
  assert.equal(manager.list().find((task) => task.id === third.id)?.status, "queued");

  executor.runs[0]?.push({ type: "done", result: "ok" });
  await settle();
  assert.equal(executor.runs.length, 3);
  assert.equal(manager.list().find((task) => task.id === third.id)?.status, "running");
});

test("ошибка исполнителя переводит задачу в failed", async () => {
  const { executor, events, manager } = setup();
  manager.submit({ prompt: "x" });
  await settle();
  executor.runs[0]?.push({ type: "failed", error: { kind: "auth", message: "Not logged in" } });
  await settle();

  const last = events.at(-1);
  assert.equal(last?.event, "task.failed");
  assert.deepEqual(last?.task.error, { kind: "auth", message: "Not logged in" });
});

test("отмена выполняющейся задачи прерывает исполнителя", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x" });
  await settle();

  assert.equal(manager.cancel(task.id), true);
  await settle();
  assert.equal(executor.runs[0]?.request.signal.aborted, true);
  assert.deepEqual(events.map((entry) => entry.event), ["task.started", "task.cancelled"]);
  assert.equal(manager.cancel(task.id), false);
});

test("отмена задачи в очереди: исполнитель не запускается", async () => {
  const { executor, events, manager } = setup(1);
  manager.submit({ prompt: "1" });
  const queued = manager.submit({ prompt: "2" });
  await settle();

  manager.cancel(queued.id);
  executor.runs[0]?.push({ type: "done", result: "ok" });
  await settle();

  assert.equal(executor.runs.length, 1);
  assert.deepEqual(events.map((entry) => entry.event), ["task.started", "task.cancelled", "task.done"]);
});
