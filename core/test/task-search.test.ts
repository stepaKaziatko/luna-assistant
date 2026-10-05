import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { TaskInfo, TaskSubmitParams } from "../src/rpc/protocol.gen.ts";
import { openHistory, type StoredTask, type TaskHistory } from "../src/tasks/history.ts";
import { ActiveDialogError, LIST_LIMIT, TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun, quietPeriod, until } from "./support/wait.ts";

const quiet = () => {};

function dataDir(): string {
  return mkdtempSync(join(tmpdir(), "luna-data-"));
}

/** Ядро на каталоге данных, как в main.ts; `seed` пишет задачи в историю до старта менеджера. */
async function start(dir = dataDir(), seed: { task: TaskInfo; workdir?: string }[] = []) {
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history, "история открылась");
  for (const { task, workdir } of seed) history.save(task, workdir);
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const tasksDir = join(dir, "tasks");
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir,
    history,
    emit: (event, task) => events.push({ event, task }),
  });
  const find = (id: string) => manager.list().find((task) => task.id === id);

  /** Отправляет задачу и проводит её до конца: сессия и ответ. */
  const finish = async (params: TaskSubmitParams, result = "ok") => {
    const index = executor.runs.length;
    const task = manager.submit(params);
    const run = await nextRun(executor, index);
    run.push({ type: "session", sessionId: `s-${task.id}` });
    run.push({ type: "done", result });
    await until(() => find(task.id)?.status === "done", "завершения задачи");
    return task;
  };

  /** Отправляет задачу и дожидается запуска исполнителя. */
  const startRun = async (params: TaskSubmitParams) => {
    const index = executor.runs.length;
    const task = manager.submit(params);
    return { task, run: await nextRun(executor, index) };
  };

  return { dir, tasksDir, history, executor, events, manager, find, finish, startRun };
}

function stored(id: string, createdAt: number, fields: Partial<TaskInfo> = {}): { task: TaskInfo } {
  return {
    task: { id, threadId: id, prompt: `запрос ${id}`, status: "done", executor: "claude-code", result: `ответ ${id}`, createdAt, finishedAt: createdAt + 1, ...fields },
  };
}

const ids = (tasks: TaskInfo[]) => tasks.map((task) => task.id).sort();
const search = (manager: TaskManager, query: string) => ids(manager.list({ query }));

test("поиск: без учёта регистра в запросе и ответе, по всей истории, а не по последним 200", async () => {
  const newer = Array.from({ length: LIST_LIMIT + 50 }, (_, index) => stored(`new-${index}`, 1000 + index));
  const core = await start(dataDir(), [
    stored("in-prompt", 1, { prompt: "Сделай перевод абзаца" }),
    stored("in-result", 2, { result: "Перевод: hello — привет" }),
    stored("other", 3, { prompt: "погода", result: "солнечно" }),
    ...newer,
  ]);

  assert.ok(!core.manager.list().some((task) => task.id === "in-prompt"), "без запроса старой задачи в списке нет");
  assert.deepEqual(search(core.manager, "ПЕРЕВОД"), ["in-prompt", "in-result"]);
  assert.deepEqual(search(core.manager, "  перевод  "), ["in-prompt", "in-result"], "пробелы по краям обрезаются");
  assert.deepEqual(search(core.manager, "перевод абзаца"), ["in-prompt"], "фраза ищется целиком");
});

test("поиск: %, _ и \\ в запросе ищутся буквально", async () => {
  const core = await start(dataDir(), [
    stored("percent", 1, { prompt: "скидка 50%_" }),
    stored("words", 2, { prompt: "скидка 50 процентов" }),
    stored("slash", 3, { result: "путь C:\\dir" }),
    stored("no-slash", 4, { result: "путь C:dir" }),
  ]);
  assert.deepEqual(search(core.manager, "50%_"), ["percent"]);
  assert.deepEqual(search(core.manager, "50%"), ["percent"]);
  assert.deepEqual(search(core.manager, "C:\\d"), ["slash"]);
  assert.deepEqual(search(core.manager, "_"), ["percent"]);
});

test("поиск: совпадение в уточнении отдаёт весь диалог; совпавших больше 200 — отдаются 200 самых новых", async () => {
  const many = Array.from({ length: LIST_LIMIT + 30 }, (_, index) => stored(`m-${index}`, 100 + index, { prompt: `перевод ${index}` }));
  const core = await start(dataDir(), [
    stored("first", 1, { prompt: "сводка", result: "готово" }),
    stored("follow", 2, { threadId: "first", prompt: "а слово «Ключ»?", result: "ключ — key" }),
    stored("lonely", 3),
    ...many,
  ]);

  const dialog = core.manager.list({ query: "КЛЮЧ" });
  assert.deepEqual(ids(dialog), ["first", "follow"]);
  assert.deepEqual(dialog.map((task) => task.id), ["follow", "first"], "новые первыми");

  const found = core.manager.list({ query: "перевод" });
  assert.equal(found.length, LIST_LIMIT);
  assert.deepEqual(ids(found), ids(many.slice(-LIST_LIMIT).map(({ task }) => task)));
});

test("поиск: задачи в памяти без истории находятся; запрос из пробелов — обычный список", async () => {
  const executor = new ManualExecutor();
  const manager = new TaskManager({ executors: [executor], defaultExecutor: "claude-code", tasksDir: join(dataDir(), "tasks"), emit: quiet });
  const done = manager.submit({ prompt: "x" });
  (await nextRun(executor, 0)).push({ type: "done", result: "Перевод готов" });
  const running = manager.submit({ prompt: "Ещё ПЕРЕВОД" });
  await nextRun(executor, 1);
  manager.submit({ prompt: "посторонняя" });
  await nextRun(executor, 2);
  await until(() => manager.list().find((task) => task.id === done.id)?.status === "done", "завершения задачи");

  assert.deepEqual(search(manager, "перевод"), [done.id, running.id].sort());
  assert.deepEqual(manager.list({ query: "   " }), manager.list());
  assert.deepEqual(manager.list({}), manager.list());
});

test("delete: удаляет диалог целиком — по id первой задачи и по id уточнения, с рабочими директориями", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "сводка" }, "ответ");
  const followUp = await core.finish({ prompt: "подробнее", followUpOf: first.id });
  const other = await core.finish({ prompt: "другая" });
  const followOther = await core.finish({ prompt: "ещё", followUpOf: other.id });
  const keep = await core.finish({ prompt: "останется" });
  for (const id of [first.id, other.id, keep.id]) assert.ok(existsSync(join(core.tasksDir, id)), `директория ${id}`);

  assert.deepEqual((await core.manager.delete(followUp.id)).sort(), [first.id, followUp.id].sort());
  assert.deepEqual((await core.manager.delete(other.id)).sort(), [other.id, followOther.id].sort());

  assert.deepEqual(ids(core.manager.list()), [keep.id]);
  assert.deepEqual(search(core.manager, "сводка"), []);
  assert.ok(!existsSync(join(core.tasksDir, first.id)));
  assert.ok(!existsSync(join(core.tasksDir, other.id)));
  assert.ok(existsSync(join(core.tasksDir, keep.id)));

  core.history.close();
  const reopened = await openHistory(core.dir, { log: quiet });
  assert.deepEqual(reopened?.recent(10).map(({ task }) => task.id), [keep.id]);
  for (const id of [first.id, followUp.id, other.id, followOther.id]) assert.equal(reopened?.get(id), undefined);
  reopened?.close();
});

test("delete: диалог с задачей в работе или в очереди — ActiveDialogError, ничего не удалено; неизвестная задача — пустой список", async () => {
  const dir = dataDir();
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history);
  const executor = new ManualExecutor();
  const manager = new TaskManager({ executors: [executor], defaultExecutor: "claude-code", tasksDir: join(dir, "tasks"), maxConcurrent: 1, history, emit: quiet });

  const first = manager.submit({ prompt: "сводка" });
  const run = await nextRun(executor, 0);
  run.push({ type: "session", sessionId: "s1" });
  run.push({ type: "done", result: "ok" });
  await until(() => manager.list().find((task) => task.id === first.id)?.status === "done", "завершения задачи");
  // Уточнение к завершённой задаче выполняется, ещё одна задача ждёт в очереди.
  const followUp = manager.submit({ prompt: "подробнее", followUpOf: first.id });
  await nextRun(executor, 1);
  const queued = manager.submit({ prompt: "в очереди" });

  await assert.rejects(manager.delete(first.id), ActiveDialogError);
  await assert.rejects(manager.delete(followUp.id), ActiveDialogError);
  await assert.rejects(manager.delete(queued.id), ActiveDialogError);
  assert.deepEqual(ids(manager.list()), [first.id, followUp.id, queued.id].sort());
  assert.ok(history.get(first.id));
  assert.ok(existsSync(join(dir, "tasks", first.id)));

  assert.deepEqual(await manager.delete("missing"), []);
  // После отмены диалог удаляется сразу.
  manager.cancel(followUp.id);
  assert.deepEqual((await manager.delete(first.id)).sort(), [first.id, followUp.id].sort());
});

test("delete: рабочая директория вне <dataDir>/tasks не трогается, запись удаляется", async () => {
  const outside = dataDir();
  writeFileSync(join(outside, "keep.txt"), "важное");
  const core = await start(dataDir(), [{ ...stored("far", 1), workdir: outside }]);
  const inside = join(core.tasksDir, "far");
  mkdirSync(inside, { recursive: true });

  assert.deepEqual(await core.manager.delete("far"), ["far"]);
  assert.equal(core.history.get("far"), undefined);
  assert.equal(readFileSync(join(outside, "keep.txt"), "utf8"), "важное");
  assert.ok(!existsSync(inside), "директория по id задачи внутри tasks удалена");
});

test("clear: удаляет завершённый и отменённый диалоги, диалог с выполняющимся уточнением остаётся целиком", async () => {
  const core = await start();
  const done = await core.finish({ prompt: "готовая" });
  const cancelled = await core.startRun({ prompt: "отменённая" });
  core.manager.cancel(cancelled.task.id);
  const base = await core.finish({ prompt: "основа" });
  const active = await core.startRun({ prompt: "уточнение", followUpOf: base.id });

  assert.deepEqual((await core.manager.clear()).sort(), [done.id, cancelled.task.id].sort());
  assert.deepEqual(ids(core.manager.list()), [base.id, active.task.id].sort());
  assert.deepEqual(core.history.thread(base.id).map(({ task }) => task.id), [base.id, active.task.id]);
  assert.equal(core.history.get(done.id), undefined);
  assert.ok(!existsSync(join(core.tasksDir, done.id)));
  assert.ok(existsSync(join(core.tasksDir, base.id)));
});

test("clear и delete затирают удалённый текст в файле history.db", async () => {
  const core = await start(dataDir(), [
    stored("deleted", 1, { prompt: "секрет-запрос-7f3a", result: "секрет-ответ-91bc" }),
    stored("cleared", 2, { prompt: "тайна-запрос-c41d", result: "тайна-ответ-e85f" }),
  ]);
  const file = join(core.dir, "history.db");
  const contains = (text: string) => readFileSync(file).includes(Buffer.from(text));
  assert.ok(contains("секрет-ответ-91bc") && contains("тайна-запрос-c41d"), "текст записан в файл");

  await core.manager.delete("deleted");
  assert.ok(!contains("секрет-запрос-7f3a") && !contains("секрет-ответ-91bc"));
  await core.manager.clear();
  assert.ok(!contains("тайна-запрос-c41d") && !contains("тайна-ответ-e85f"));
});

test("удалённая задача не воскресает: исполнитель, завершивший поток после удаления, её не записывает", async () => {
  const core = await start();
  const { task, run } = await core.startRun({ prompt: "долгая" });
  core.manager.cancel(task.id);
  assert.deepEqual(await core.manager.delete(task.id), [task.id]);

  run.push({ type: "session", sessionId: "late" });
  run.push({ type: "done", result: "поздний ответ" });
  await quietPeriod();
  assert.equal(core.find(task.id), undefined);
  assert.equal(core.history.get(task.id), undefined);
  assert.deepEqual(core.events.filter((entry) => entry.task.id === task.id).map((entry) => entry.event), ["task.started", "task.cancelled"]);
});

test("удалённая задача не воскресает: отменена и удалена, пока готовилась её рабочая директория", async () => {
  const dir = dataDir();
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history);
  const executor = new ManualExecutor();
  const events: TaskEventName[] = [];
  const pending: Promise<string[]>[] = [];
  const manager: TaskManager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    history,
    // task.started приходит до создания директории: отмена и удаление успевают раньше неё.
    emit: (event, task) => {
      events.push(event);
      if (event !== "task.started") return;
      manager.cancel(task.id);
      pending.push(manager.delete(task.id));
    },
  });
  const task = manager.submit({ prompt: "долгая" });
  await until(() => pending.length === 1, "удаления");
  assert.deepEqual(await pending[0], [task.id]);
  await quietPeriod();

  assert.equal(history.get(task.id), undefined);
  assert.deepEqual(manager.list(), []);
  assert.deepEqual(events, ["task.started", "task.cancelled"]);
  assert.equal(executor.runs.length, 0, "исполнитель отменённой задачи не запускается");
});

test("сбой истории при удалении: ошибка, в памяти ничего не удалено", async () => {
  const failing: TaskHistory = {
    save: () => {},
    recent: () => [],
    get: () => undefined,
    thread: () => [],
    search: () => [],
    deleteThreads: (): StoredTask[] => {
      throw new Error("database or disk is full");
    },
    deleteThreadsExcept: (): StoredTask[] => {
      throw new Error("database or disk is full");
    },
    close: () => {},
  };
  const executor = new ManualExecutor();
  const manager = new TaskManager({ executors: [executor], defaultExecutor: "claude-code", tasksDir: join(dataDir(), "tasks"), history: failing, emit: quiet });
  const task = manager.submit({ prompt: "x" });
  (await nextRun(executor, 0)).push({ type: "done", result: "ok" });
  await until(() => manager.list()[0]?.status === "done", "завершения задачи");

  await assert.rejects(manager.delete(task.id), /disk is full/);
  await assert.rejects(manager.clear(), /disk is full/);
  assert.deepEqual(ids(manager.list()), [task.id]);
});
