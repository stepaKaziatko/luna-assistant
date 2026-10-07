import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExecutorEvent, PauseRequest } from "../src/executors/executor.ts";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { openHistory } from "../src/tasks/history.ts";
import { ApprovalError, TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
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

// --- Пауза исполнителя: подтверждение действия

/** Событие паузы с подставным ответом: тест видит, что и когда ответили. */
function pause(request: Partial<PauseRequest> = {}) {
  const answers: boolean[] = [];
  const event: Extract<ExecutorEvent, { type: "pause" }> = {
    type: "pause",
    kind: "approval",
    request: { tool: "Write", kind: "write", summary: "Записать файл", target: "/work/hello.txt", detail: "hi", ...request },
    respond: (allow) => answers.push(allow),
  };
  return { event, answers };
}

test("пауза: task.needs_approval со снимком running и approval; approve(allow) отвечает исполнителю и шлёт progress без approval", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "создай файл" });
  const run = await nextRun(executor, 0);
  const { event, answers } = pause();
  run.push(event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");

  const waiting = events.at(-1)?.task;
  assert.equal(waiting?.status, "running");
  const approval = waiting?.approval;
  assert.ok(approval, "в снимке нет approval");
  assert.ok(approval.id);
  assert.equal(approval.tool, "Write");
  assert.equal(approval.kind, "write");
  assert.equal(approval.summary, "Записать файл");
  assert.equal(approval.target, "/work/hello.txt");
  assert.equal(approval.detail, "hi");
  assert.ok(approval.createdAt > 0);
  assert.deepEqual(answers, []);

  manager.approve(task.id, approval.id, true);
  assert.deepEqual(answers, [true]);
  assert.equal(events.at(-1)?.event, "task.progress");
  assert.equal(events.at(-1)?.task.approval, undefined);
  assert.equal(events.at(-1)?.task.status, "running");

  run.push({ type: "done", result: "готово" });
  await until(() => eventNames(events).includes("task.done"), "завершения задачи");
  assert.equal(events.at(-1)?.task.approval, undefined);
  assert.deepEqual(eventNames(events), ["task.started", "task.needs_approval", "task.progress", "task.done"]);
});

test("approve: чужой approvalId, неизвестная задача и задача без ожидания — ApprovalError, исполнителю не отвечают; отказ уходит как false", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  assert.throws(() => manager.approve(task.id, "any", true), ApprovalError);

  const { event, answers } = pause();
  run.push(event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");
  const approvalId = events.at(-1)?.task.approval?.id ?? "";

  assert.throws(() => manager.approve(task.id, "stale", true), ApprovalError);
  assert.throws(() => manager.approve("missing", approvalId, true), ApprovalError);
  assert.deepEqual(answers, []);
  assert.equal(manager.list().find((listed) => listed.id === task.id)?.approval?.id, approvalId, "запрос на месте");

  manager.approve(task.id, approvalId, false);
  assert.deepEqual(answers, [false]);
  // Повторный ответ на тот же запрос — уже устарел.
  assert.throws(() => manager.approve(task.id, approvalId, true), ApprovalError);
  assert.deepEqual(answers, [false]);
});

test("отмена в ожидании: task.cancelled без approval; снимок в истории без approval", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-tasks-"));
  const history = await openHistory(dir, { log: () => {} });
  assert.ok(history);
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    history,
    emit: (event, task) => events.push({ event, task }),
  });
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  run.push(pause().event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");
  assert.equal(history.get(task.id)?.task.approval, undefined, "ожидание в историю не пишется");

  assert.equal(manager.cancel(task.id), true);
  const cancelled = events.at(-1);
  assert.equal(cancelled?.event, "task.cancelled");
  assert.equal(cancelled?.task.approval, undefined);
  assert.equal(history.get(task.id)?.task.status, "cancelled");
  assert.equal(history.get(task.id)?.task.approval, undefined);
  history.close();
});

test("второй запрос при висящем первом заменяет его: прежний закрывается отказом, новый id в снимке", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  const first = pause({ target: "/work/a.txt" });
  run.push(first.event);
  await until(() => eventNames(events).includes("task.needs_approval"), "первого запроса");
  const firstId = events.at(-1)?.task.approval?.id ?? "";

  const second = pause({ target: "/work/b.txt" });
  run.push(second.event);
  await until(() => events.filter((entry) => entry.event === "task.needs_approval").length === 2, "второго запроса");
  assert.deepEqual(first.answers, [false]);
  const secondId = events.at(-1)?.task.approval?.id ?? "";
  assert.notEqual(secondId, firstId);
  assert.equal(events.at(-1)?.task.approval?.target, "/work/b.txt");
  assert.throws(() => manager.approve(task.id, firstId, true), ApprovalError);
  manager.approve(task.id, secondId, true);
  assert.deepEqual(second.answers, [true]);
});
