import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExecutorEvent, PauseRequest } from "../src/executors/executor.ts";
import type { TaskInfo } from "../src/rpc/protocol.gen.ts";
import { INTERRUPTED_MESSAGE, openHistory } from "../src/tasks/history.ts";
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

// --- Жизненный цикл подтверждения (LUNA-49)

/** Менеджер на истории во временном каталоге — для проверок записи и перезапуска. */
async function setupWithHistory(dir = mkdtempSync(join(tmpdir(), "luna-tasks-"))) {
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
  return { dir, history, executor, events, manager };
}

const approvals = (events: { event: TaskEventName }[]) => events.filter((entry) => entry.event === "task.needs_approval").length;

/** Задача, которая поставила две паузы подряд; ждём показа первой. */
async function twoPauses(setupResult: { executor: ManualExecutor; events: { event: TaskEventName; task: TaskInfo }[]; manager: TaskManager }) {
  const { executor, events, manager } = setupResult;
  const task = manager.submit({ prompt: "запиши два файла" });
  const run = await nextRun(executor, 0);
  const first = pause({ target: "/work/a.txt" });
  const second = pause({ target: "/work/b.txt" });
  run.push(first.event);
  run.push(second.event);
  await until(() => approvals(events) === 1, "первого запроса");
  await quietPeriod();
  return { task, run, first, second };
}

test("очередь в задаче: второй запрос ждёт ответа на первый, затем показывается новым task.needs_approval; после него — progress без approval", async () => {
  const state = setup();
  const { events, manager } = state;
  const { task, run, first, second } = await twoPauses(state);

  assert.equal(approvals(events), 1, "второй запрос не показан, пока висит первый");
  const firstId = events.at(-1)?.task.approval?.id ?? "";
  assert.equal(events.at(-1)?.task.approval?.target, "/work/a.txt");
  assert.deepEqual(first.answers, []);
  assert.deepEqual(second.answers, [], "второй не отклонён и не отвечен");
  assert.equal(manager.list().find((info) => info.id === task.id)?.approval?.id, firstId, "в снимке — самый старый");

  manager.approve(task.id, firstId, true);
  assert.deepEqual(first.answers, [true]);
  assert.deepEqual(second.answers, []);
  const shown = events.at(-1);
  assert.equal(shown?.event, "task.needs_approval");
  assert.equal(shown?.task.status, "running");
  assert.equal(shown?.task.approval?.target, "/work/b.txt");
  const secondId = shown?.task.approval?.id ?? "";
  assert.notEqual(secondId, firstId);
  assert.ok((shown?.task.approval?.createdAt ?? 0) >= (events.find((entry) => entry.event === "task.needs_approval")?.task.approval?.createdAt ?? Infinity));

  // Ответ первым id после смены — устарел и второму не достаётся.
  assert.throws(() => manager.approve(task.id, firstId, false), ApprovalError);
  assert.deepEqual(second.answers, []);

  manager.approve(task.id, secondId, false);
  assert.deepEqual(second.answers, [false]);
  assert.equal(events.at(-1)?.event, "task.progress");
  assert.equal(events.at(-1)?.task.approval, undefined);
  assert.throws(() => manager.approve(task.id, secondId, true), ApprovalError);

  run.push({ type: "done", result: "готово" });
  await until(() => eventNames(events).includes("task.done"), "завершения задачи");
  assert.deepEqual(eventNames(events), ["task.started", "task.needs_approval", "task.needs_approval", "task.progress", "task.done"]);
});

test("отмена в ожидании: все запросы очереди получают отказ до abort, task.cancelled без approval, повторный approve — ApprovalError", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "запиши два файла" });
  const run = await nextRun(executor, 0);
  // Каждый ответ запоминает, был ли запуск уже остановлен: отказ должен прийти раньше остановки.
  const answers: { allow: boolean; aborted: boolean }[] = [];
  for (const target of ["/work/a.txt", "/work/b.txt"]) {
    const { event } = pause({ target });
    event.respond = (allow) => answers.push({ allow, aborted: run.request.signal.aborted });
    run.push(event);
  }
  await until(() => approvals(events) === 1, "первого запроса");
  await quietPeriod();
  const approvalId = events.at(-1)?.task.approval?.id ?? "";

  assert.equal(manager.cancel(task.id), true);
  assert.deepEqual(answers, [{ allow: false, aborted: false }, { allow: false, aborted: false }]);
  assert.equal(run.request.signal.aborted, true, "abort у сигнала запуска");
  const cancelled = events.at(-1);
  assert.equal(cancelled?.event, "task.cancelled");
  assert.equal(cancelled?.task.approval, undefined);
  assert.throws(() => manager.approve(task.id, approvalId, true), ApprovalError);
  await quietPeriod();
  assert.equal(answers.length, 2, "ответ на каждый запрос — один");
  assert.equal(manager.list().find((info) => info.id === task.id)?.approval, undefined);
});

test("отмена в ожидании: task.cancelled без approval; снимок в истории без approval", async () => {
  const { history, executor, events, manager } = await setupWithHistory();
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  const { event, answers } = pause();
  run.push(event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");
  assert.equal(history.get(task.id)?.task.approval, undefined, "ожидание в историю не пишется");

  assert.equal(manager.cancel(task.id), true);
  assert.deepEqual(answers, [false]);
  const cancelled = events.at(-1);
  assert.equal(cancelled?.event, "task.cancelled");
  assert.equal(cancelled?.task.approval, undefined);
  assert.equal(history.get(task.id)?.task.status, "cancelled");
  assert.equal(history.get(task.id)?.task.approval, undefined);
  history.close();
});

test("shutdown в ожидании: отказ всем запросам, abort, в истории — failed с INTERRUPTED_MESSAGE без approval; после перезапуска запроса нет", async () => {
  const state = await setupWithHistory();
  const { dir, history, events, manager } = state;
  const { task, run, first, second } = await twoPauses(state);
  const eventsBefore = events.length;

  manager.shutdown();
  assert.deepEqual(first.answers, [false]);
  assert.deepEqual(second.answers, [false]);
  assert.equal(run.request.signal.aborted, true);
  assert.equal(events.length, eventsBefore, "событий при выходе нет");
  const stored = history.get(task.id)?.task;
  assert.equal(stored?.status, "failed");
  assert.deepEqual(stored?.error, { kind: "unknown", message: INTERRUPTED_MESSAGE });
  assert.equal(stored?.approval, undefined);
  history.close();

  const restarted = await setupWithHistory(dir);
  const listed = restarted.manager.list().find((info) => info.id === task.id);
  assert.equal(listed?.status, "failed");
  assert.equal(listed?.error?.message, INTERRUPTED_MESSAGE);
  assert.equal(listed?.approval, undefined);
  assert.throws(() => restarted.manager.approve(task.id, "any", true), ApprovalError);
  restarted.history.close();
});

test("сбой исполнителя в ожидании: failed (rate_limit) и поток без итога — task.failed без approval, запросы получают отказ", async () => {
  {
    const state = setup();
    const { events, manager } = state;
    const { task, run, first, second } = await twoPauses(state);
    run.push({ type: "failed", error: { kind: "rate_limit", message: "лимит" } });
    await until(() => eventNames(events).includes("task.failed"), "ошибки задачи");
    const failed = events.at(-1);
    assert.equal(failed?.task.error?.kind, "rate_limit");
    assert.equal(failed?.task.approval, undefined);
    assert.deepEqual(first.answers, [false]);
    assert.deepEqual(second.answers, [false]);
    assert.throws(() => manager.approve(task.id, "any", true), ApprovalError);
  }
  {
    // Поток кончился без итога: исполнитель закрыл его, не прислав done/failed.
    const executor = new ManualExecutor();
    const events: { event: TaskEventName; task: TaskInfo }[] = [];
    const answers: boolean[] = [];
    executor.run = async function* () {
      yield { type: "pause", kind: "approval", request: { tool: "Write", kind: "write", summary: "Записать файл" }, respond: (allow: boolean) => answers.push(allow) };
      await quietPeriod();
    };
    const manager = new TaskManager({
      executors: [executor],
      defaultExecutor: "claude-code",
      tasksDir: mkdtempSync(join(tmpdir(), "luna-tasks-")),
      emit: (event, task) => events.push({ event, task }),
    });
    manager.submit({ prompt: "x" });
    await until(() => eventNames(events).includes("task.failed"), "ошибки задачи");
    assert.deepEqual(eventNames(events), ["task.started", "task.needs_approval", "task.failed"]);
    assert.equal(events.at(-1)?.task.approval, undefined);
    assert.deepEqual(answers, [false]);
  }
});

test("слот: ждущая подтверждения задача держит maxConcurrent, следующая стоит в очереди до её завершения", async () => {
  const { executor, events, manager } = setup(1);
  const first = manager.submit({ prompt: "1" });
  const second = manager.submit({ prompt: "2" });
  const run = await nextRun(executor, 0);
  run.push(pause().event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");
  await quietPeriod();
  assert.equal(executor.runs.length, 1);
  assert.equal(manager.list().find((info) => info.id === second.id)?.status, "queued");

  manager.approve(first.id, manager.list().find((info) => info.id === first.id)?.approval?.id ?? "", true);
  await quietPeriod();
  assert.equal(executor.runs.length, 1, "после ответа задача ещё работает — слот занят");
  run.push({ type: "done", result: "ok" });
  await nextRun(executor, 1);
  assert.equal(manager.list().find((info) => info.id === second.id)?.status, "running");
});

test("порядок между задачами: паузы A, затем B — createdAt A ≤ B, list() отдаёт обе с approval", async () => {
  const { executor, events, manager } = setup();
  const a = manager.submit({ prompt: "a" });
  const b = manager.submit({ prompt: "b" });
  await nextRun(executor, 1);
  const runOf = (id: string) => executor.runs.find((run) => run.request.cwd.endsWith(id));
  runOf(a.id)?.push(pause().event);
  await until(() => approvals(events) === 1, "запроса A");
  await new Promise((resolve) => setTimeout(resolve, 2));
  runOf(b.id)?.push(pause().event);
  await until(() => approvals(events) === 2, "запроса B");

  const listed = manager.list();
  const approvalA = listed.find((info) => info.id === a.id)?.approval;
  const approvalB = listed.find((info) => info.id === b.id)?.approval;
  assert.ok(approvalA && approvalB);
  assert.ok(approvalA.createdAt <= approvalB.createdAt);
  assert.notEqual(approvalA.id, approvalB.id);
});

// --- Веб: только чтение (LUNA-47)

test("readOnly: задача с url в контексте получает его, без url — поля нет", async () => {
  const { executor, manager } = setup();
  manager.submit({ prompt: "сводка", context: { url: "https://github.com/o/r", title: "o/r" } });
  manager.submit({ prompt: "заметка", context: { selection: "текст" } });
  manager.submit({ prompt: "просто" });
  await nextRun(executor, 2);
  // Запуски стартуют в порядке готовности директорий, а не отправки: ищем по тексту запроса.
  const requestOf = (prompt: string) => executor.runs.find((run) => run.request.prompt.includes(`<task>\n${prompt}\n</task>`))?.request;
  assert.equal(requestOf("сводка")?.readOnly, true);
  assert.equal("readOnly" in (requestOf("заметка") ?? {}), false);
  assert.equal("readOnly" in (requestOf("просто") ?? {}), false);
  assert.ok(requestOf("заметка") && requestOf("просто"));
});

test("после события web пауза отклоняется сразу: task.needs_approval не уходит, approval не появляется", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "найди и запиши" });
  const run = await nextRun(executor, 0);
  run.push({ type: "web" });
  const { event, answers } = pause();
  run.push(event);
  await until(() => answers.length > 0, "отказа исполнителю");
  assert.deepEqual(answers, [false]);
  assert.equal(manager.list().find((info) => info.id === task.id)?.approval, undefined);
  run.push({ type: "done", result: "записать нельзя" });
  await until(() => eventNames(events).includes("task.done"), "завершения задачи");
  assert.equal(eventNames(events).includes("task.needs_approval"), false);
  assert.throws(() => manager.approve(task.id, "x", true), ApprovalError);
});

test("событие web при висящем запросе закрывает его и очередь отказом и снимает approval", async () => {
  const { executor, events, manager } = setup();
  const task = manager.submit({ prompt: "x" });
  const run = await nextRun(executor, 0);
  const { event, answers } = pause();
  const queued = pause({ target: "/work/b.txt" });
  run.push(event);
  run.push(queued.event);
  await until(() => eventNames(events).includes("task.needs_approval"), "запроса подтверждения");
  const approvalId = events.at(-1)?.task.approval?.id ?? "";
  run.push({ type: "web" });
  await until(() => answers.length > 0, "отказа исполнителю");
  assert.deepEqual(answers, [false]);
  assert.deepEqual(queued.answers, [false], "запрос из очереди тоже отклонён");
  assert.equal(approvals(events), 1, "запрос из очереди не показан");
  assert.equal(events.at(-1)?.event, "task.progress");
  assert.equal(events.at(-1)?.task.approval, undefined);
  assert.throws(() => manager.approve(task.id, approvalId, true), ApprovalError);
  run.push({ type: "done", result: "ок" });
  await until(() => eventNames(events).includes("task.done"), "завершения задачи");
});
