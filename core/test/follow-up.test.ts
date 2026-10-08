import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { buildPrompt, FORMAT_RULES } from "../src/prompt/build.ts";
import type { TaskError, TaskInfo, TaskSubmitParams } from "../src/rpc/protocol.gen.ts";
import { openHistory } from "../src/tasks/history.ts";
import { FollowUpError, RESEND_PROGRESS, TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun as nextRunOf, quietPeriod, until } from "./support/wait.ts";

const quiet = () => {};

/** Ядро на каталоге данных, как в main.ts: история на диске и менеджер поверх неё. */
async function start(dir = mkdtempSync(join(tmpdir(), "luna-data-"))) {
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history, "история открылась");
  // Каждая запись в историю — снимком: видно, какие статусы задача проходила на диске.
  const saves: TaskInfo[] = [];
  const save = history.save.bind(history);
  history.save = (task, workdir, webUsed) => {
    saves.push({ ...task });
    save(task, workdir, webUsed);
  };
  const executor = new ManualExecutor();
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    history,
    emit: (event, task) => events.push({ event, task }),
  });

  /** Отправляет задачу и проводит её запуск до конца: сессия и результат либо ошибка. */
  const finish = async (
    params: TaskSubmitParams,
    outcome: { sessionId?: string; result?: string; error?: TaskError } = {},
  ) => {
    const started = executor.runs.length;
    const task = manager.submit(params);
    const run = await nextRun(started);
    if (outcome.sessionId) run.push({ type: "session", sessionId: outcome.sessionId });
    run.push(outcome.error ? { type: "failed", error: outcome.error } : { type: "done", result: outcome.result ?? "ok" });
    await until(() => find(task.id)?.status !== "running", "завершения задачи");
    return { task, run };
  };

  /** Запуск исполнителя с номером `index` — дожидается его. */
  const nextRun = (index: number) => nextRunOf(executor, index);

  /** Отправляет задачу и дожидается запуска исполнителя — после этого её можно отменять. */
  const startRun = async (params: TaskSubmitParams) => {
    const started = executor.runs.length;
    const task = manager.submit(params);
    return { task, run: await nextRun(started) };
  };

  const find = (id: string) => manager.list().find((task) => task.id === id);
  /** События одной задачи по порядку. */
  const eventsOf = (id: string) => events.filter((entry) => entry.task.id === id);
  return { dir, history, saves, executor, manager, finish, nextRun, startRun, find, eventsOf };
}

const rejects = (manager: TaskManager, followUpOf: string) =>
  assert.throws(() => manager.submit({ prompt: "ещё", followUpOf }), FollowUpError);

test("уточнение: тот же диалог и исполнитель, та же директория, промпт только <task>, --resume прежней сессии", async () => {
  const core = await start();
  const first = await core.finish(
    { prompt: "сводка", context: { url: "https://github.com/o/r", selection: "текст" } },
    { sessionId: "s1", result: "ответ" },
  );
  assert.equal(first.task.threadId, first.task.id, "у обычной задачи threadId == id");

  const followUp = core.manager.submit({ prompt: "  а покороче?  ", followUpOf: first.task.id });
  assert.equal(followUp.threadId, first.task.id);
  assert.equal(followUp.executor, first.task.executor);
  assert.equal(followUp.context, undefined);

  const run = await core.nextRun(1);
  assert.equal(run.request.prompt, "<task>\nа покороче?\n</task>");
  assert.equal(run.request.formatRules, FORMAT_RULES);
  assert.equal(run.request.cwd, first.run.request.cwd);
  assert.deepEqual(run.request.resume, { sessionId: "s1" });
  assert.equal(first.run.request.resume, undefined, "обычная задача сессию не продолжает");

  // sessionId уточнения — из его собственного потока.
  run.push({ type: "session", sessionId: "s2" });
  run.push({ type: "done", result: "коротко" });
  await until(() => core.find(followUp.id)?.status === "done");
  assert.equal(core.find(followUp.id)?.sessionId, "s2");
  assert.equal(core.history.get(followUp.id)?.workdir, first.run.request.cwd);

  // Цепочка из трёх: threadId — id первой задачи, сессия — последнего ответа.
  const third = core.manager.submit({ prompt: "ещё короче", followUpOf: followUp.id });
  assert.equal(third.threadId, first.task.id);
  const thirdRun = await core.nextRun(2);
  assert.deepEqual(thirdRun.request.resume, { sessionId: "s2" });
  assert.equal(thirdRun.request.cwd, first.run.request.cwd);
});

test("удалённая очисткой директория создаётся заново по тому же пути", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "x" }, { sessionId: "s1" });
  const cwd = first.run.request.cwd;
  rmSync(cwd, { recursive: true, force: true });
  assert.equal(existsSync(cwd), false);

  const followUp = core.manager.submit({ prompt: "y", followUpOf: first.task.id });
  assert.equal((await core.nextRun(1)).request.cwd, cwd);
  assert.equal(existsSync(cwd), true);
  assert.equal(core.history.get(followUp.id)?.workdir, cwd);
});

test("followUpOf отклоняется: задачи нет, не done, без сессии, не последний ответ, диалог активен, сессия потеряна", async () => {
  const core = await start();
  rejects(core.manager, "missing");

  const failed = await core.finish({ prompt: "f" }, { sessionId: "sf", error: { kind: "auth", message: "Not logged in" } });
  rejects(core.manager, failed.task.id);

  const { task: cancelled } = await core.startRun({ prompt: "c" });
  core.manager.cancel(cancelled.id);
  rejects(core.manager, cancelled.id);

  const { task: running } = await core.startRun({ prompt: "r" });
  rejects(core.manager, running.id);
  core.manager.cancel(running.id);

  const withoutSession = await core.finish({ prompt: "без сессии" });
  rejects(core.manager, withoutSession.task.id);

  // После ответа в диалоге уже есть следующий ответ — точка продолжения сдвинулась.
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1" });
  await core.finish({ prompt: "2", followUpOf: first.task.id }, { sessionId: "s2" });
  rejects(core.manager, first.task.id);

  // Пока уточнение выполняется, следующее не принимается.
  const active = await core.finish({ prompt: "a" }, { sessionId: "sa" });
  const pendingRun = core.executor.runs.length;
  const pending = core.manager.submit({ prompt: "a2", followUpOf: active.task.id });
  rejects(core.manager, active.task.id);
  await core.nextRun(pendingRun);
  rejects(core.manager, active.task.id);
  core.manager.cancel(pending.id);

  // Сессия у исполнителя потеряна, а переписку отправить заново нечем (ни одного сохранённого
  // ответа) — задача остаётся с session_not_found, и диалог не продолжается.
  const lost = await core.finish({ prompt: "l" }, { sessionId: "sl", result: "" });
  const runs = core.executor.runs.length;
  const lostFollowUp = await core.finish(
    { prompt: "l2", followUpOf: lost.task.id },
    { error: { kind: "session_not_found", message: "нет сессии" } },
  );
  assert.equal(core.find(lostFollowUp.task.id)?.error?.kind, "session_not_found");
  await quietPeriod();
  assert.equal(core.executor.runs.length, runs + 1, "повторного запуска нет");
  rejects(core.manager, lost.task.id);
});

test("неудачное или отменённое уточнение не закрывает диалог: продолжение — от последнего ответа", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1" });
  await core.finish(
    { prompt: "2", followUpOf: first.task.id },
    { error: { kind: "rate_limit", message: "лимит" } },
  );
  const { task: cancelled } = await core.startRun({ prompt: "3", followUpOf: first.task.id });
  core.manager.cancel(cancelled.id);

  const started = core.executor.runs.length;
  const accepted = core.manager.submit({ prompt: "4", followUpOf: first.task.id });
  assert.equal(accepted.threadId, first.task.id);
  assert.deepEqual((await core.nextRun(started)).request.resume, { sessionId: "s1" });
});

test("после перезапуска ядра диалог восстанавливается и продолжается, даже за пределами 200 последних", async () => {
  const before = await start();
  const first = await before.finish({ prompt: "запомни число", context: { url: "https://example.com" } }, { sessionId: "s1" });
  const second = await before.finish({ prompt: "а ещё?", followUpOf: first.task.id }, { sessionId: "s2" });
  // 250 задач новее диалога — его нет в task.list.
  const future = Date.now() + 1_000_000;
  for (let index = 0; index < 250; index += 1) {
    const id = `t${index}`;
    before.history.save({ id, threadId: id, prompt: id, status: "done", executor: "claude-code", createdAt: future + index });
  }
  before.history.close();

  const after = await start(before.dir);
  const listed = after.manager.list();
  assert.equal(listed.some((task) => task.id === second.task.id), false, "диалог за пределами списка");
  assert.ok(listed.every((task) => task.threadId === task.id));

  const followUp = after.manager.submit({ prompt: "какое число?", followUpOf: second.task.id });
  assert.equal(followUp.threadId, first.task.id);
  const run = await after.nextRun(0);
  assert.equal(run.request.cwd, first.run.request.cwd);
  assert.deepEqual(run.request.resume, { sessionId: "s2" });
  rejects(after.manager, first.task.id);

  run.push({ type: "done", result: "417" });
  // Диалог старше 200 последних — в list() его нет, смотрим в историю.
  await until(() => after.history.get(followUp.id)?.task.status === "done");
  assert.deepEqual(
    after.history.thread(first.task.id).map(({ task }) => [task.id, task.threadId]),
    [first.task.id, second.task.id, followUp.id].map((id) => [id, first.task.id]),
  );
});

test("history.db версии 1 переходит на текущую версию без потери задач", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-data-"));
  const { DatabaseSync } = await import("node:sqlite");
  const v1 = new DatabaseSync(join(dir, "history.db"));
  // Схема LUNA-23.
  v1.exec(`
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL, executor TEXT NOT NULL,
      result TEXT, error TEXT, session_id TEXT, created_at INTEGER NOT NULL, finished_at INTEGER, workdir TEXT
    );
    CREATE INDEX tasks_created_at ON tasks (created_at);
    PRAGMA user_version = 1;
    INSERT INTO tasks (id, prompt, status, executor, result, session_id, created_at, finished_at, workdir)
      VALUES ('a', 'первая', 'done', 'claude-code', 'ответ', 'sa', 1, 2, '/tmp/luna/a'),
             ('b', 'вторая', 'failed', 'claude-code', NULL, NULL, 3, 4, NULL);
  `);
  v1.close();

  const core = await start(dir);
  assert.deepEqual(readdirSync(dir).filter((name) => name.startsWith("history.broken-")), []);
  const listed = core.manager.list();
  assert.deepEqual(listed.map((task: TaskInfo) => [task.id, task.threadId, task.status]), [
    ["b", "b", "failed"],
    ["a", "a", "done"],
  ]);
  assert.equal(core.history.get("a")?.workdir, "/tmp/luna/a");
  core.history.close();

  const check = new DatabaseSync(join(dir, "history.db"));
  assert.deepEqual({ ...(check.prepare("PRAGMA user_version").get() as object) }, { user_version: 4 });
  check.close();
});

const lostSession = { type: "failed", error: { kind: "session_not_found", message: "No conversation found" } } as const;

test("сессия потеряна: переписка уходит заново тем же запуском задачи — <context> первой задачи, <history>, <task>", async () => {
  const core = await start();
  const context = { url: "https://github.com/o/r", title: "o/r", selection: "выделенный текст" };
  const first = await core.finish({ prompt: "1", context }, { sessionId: "s1", result: "ответ 1" });
  // В историю не попадают неудачные, отменённые и пустые ответы.
  await core.finish({ prompt: "2", followUpOf: first.task.id }, { error: { kind: "rate_limit", message: "лимит" } });
  const { task: cancelled } = await core.startRun({ prompt: "3", followUpOf: first.task.id });
  core.manager.cancel(cancelled.id);
  const fourth = await core.finish({ prompt: "4", followUpOf: first.task.id }, { sessionId: "s4", result: "ответ 4" });
  const fifth = await core.finish({ prompt: "5", followUpOf: fourth.task.id }, { sessionId: "s5", result: "" });

  const { task, run } = await core.startRun({ prompt: "что было в начале?", followUpOf: fifth.task.id });
  assert.deepEqual(run.request.resume, { sessionId: "s5" });
  // Поток потерянной сессии сначала называет запрошенный id.
  run.push({ type: "session", sessionId: "s5" });
  run.push(lostSession);

  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  assert.equal(retry.request.resume, undefined);
  assert.equal(retry.request.cwd, run.request.cwd);
  assert.equal(retry.request.signal, run.request.signal);
  assert.equal(
    retry.request.prompt,
    buildPrompt("что было в начале?", context, [
      { question: "1", answer: "ответ 1" },
      { question: "4", answer: "ответ 4" },
    ]),
  );
  const prompt = retry.request.prompt;
  assert.ok(prompt.indexOf("<context>") < prompt.indexOf("<history>") && prompt.indexOf("</history>") < prompt.indexOf("<task>"));
  assert.ok(prompt.indexOf("ответ 1") < prompt.indexOf("ответ 4"));
  assert.equal(core.find(task.id)?.status, "running");
  assert.equal(core.history.get(task.id)?.task.sessionId, undefined, "потерянный id не остался у задачи");

  retry.push({ type: "progress", text: "пишет ответ…" });
  retry.push({ type: "session", sessionId: "s6" });
  retry.push({ type: "done", result: "в начале был вопрос 1" });
  await until(() => core.find(task.id)?.status === "done", "завершения уточнения");

  const done = core.find(task.id);
  assert.equal(done?.threadId, first.task.id);
  assert.equal(done?.createdAt, task.createdAt);
  assert.equal(done?.result, "в начале был вопрос 1");
  assert.equal(done?.sessionId, "s6");
  const events = core.eventsOf(task.id).map(({ event, task }) => (event === "task.progress" ? task.progress : event));
  assert.deepEqual(events, ["task.started", RESEND_PROGRESS, "пишет ответ…", "task.done"]);
  assert.deepEqual(
    [...new Set(core.saves.filter((saved) => saved.id === task.id).map((saved) => saved.status))],
    ["queued", "running", "done"],
    "промежуточная ошибка в историю не пишется",
  );
  assert.equal(core.history.get(task.id)?.task.result, "в начале был вопрос 1");

  // Следующее уточнение — обычное продолжение новой сессии.
  const { run: next } = await core.startRun({ prompt: "а покороче?", followUpOf: task.id });
  assert.deepEqual(next.request.resume, { sessionId: "s6" });
  assert.equal(next.request.cwd, run.request.cwd);
  assert.equal(next.request.prompt, "<task>\nа покороче?\n</task>");
});

test("повторный запуск без собственной сессии не оставляет задаче потерянный id", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1", result: "ответ" });
  const { task, run } = await core.startRun({ prompt: "2", followUpOf: first.task.id });
  run.push({ type: "session", sessionId: "s1" });
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  // Без контекста у первой задачи блока <context> нет.
  assert.equal(retry.request.prompt, "<history>\n<question>\n1\n</question>\n<answer>\nответ\n</answer>\n</history>\n\n<task>\n2\n</task>");
  retry.push({ type: "done", result: "ок" });
  await until(() => core.find(task.id)?.status === "done", "завершения уточнения");
  assert.equal(core.find(task.id)?.sessionId, undefined);
  assert.equal(core.history.get(task.id)?.task.sessionId, undefined);
});

test("первой задачи диалога нет в истории: переписка — без <context>, с самой ранней сохранённой пары", async () => {
  const before = await start();
  const first = await before.finish({ prompt: "1", context: { url: "https://example.com" } }, { sessionId: "s1", result: "ответ 1" });
  const second = await before.finish({ prompt: "2", followUpOf: first.task.id }, { sessionId: "s2", result: "ответ 2" });
  before.history.close();
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(join(before.dir, "history.db"));
  db.prepare("DELETE FROM tasks WHERE id = ?").run(first.task.id);
  db.close();

  const after = await start(before.dir);
  const { task, run } = await after.startRun({ prompt: "3", followUpOf: second.task.id });
  run.push(lostSession);
  const retry = await after.nextRun(1);
  assert.equal(retry.request.prompt, buildPrompt("3", undefined, [{ question: "2", answer: "ответ 2" }]));
  retry.push({ type: "done", result: "ответ 3" });
  await until(() => after.history.get(task.id)?.task.status === "done", "завершения уточнения");
});

test("повторный запуск упал — обычная ошибка задачи, третьего запуска нет, диалог продолжается", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1", result: "ответ" });

  const { task: limited, run } = await core.startRun({ prompt: "2", followUpOf: first.task.id });
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  retry.push({ type: "failed", error: { kind: "rate_limit", message: "Usage limit reached" } });
  await until(() => core.find(limited.id)?.status === "failed", "ошибки уточнения");
  await quietPeriod();
  assert.deepEqual(core.find(limited.id)?.error, { kind: "rate_limit", message: "Usage limit reached" });
  assert.equal(core.executor.runs.length, 3, "первая задача, первый и повторный запуски уточнения");
  assert.deepEqual(
    core.eventsOf(limited.id).map(({ event }) => event).filter((event) => event !== "task.progress"),
    ["task.started", "task.failed"],
  );

  // Неудачное уточнение диалог не закрывает: продолжение — от прежнего ответа.
  const { task: again, run: againRun } = await core.startRun({ prompt: "3", followUpOf: first.task.id });
  assert.deepEqual(againRun.request.resume, { sessionId: "s1" });

  // Повторный запуск сам ответил «сессия не найдена» (без --resume так не бывает) — третьего нет.
  againRun.push(lostSession);
  const againRetry = await core.nextRun(core.executor.runs.indexOf(againRun) + 1);
  againRetry.push(lostSession);
  await until(() => core.find(again.id)?.status === "failed", "ошибки уточнения");
  await quietPeriod();
  assert.equal(core.executor.runs.length, 5);
  assert.equal(core.eventsOf(again.id).filter(({ event }) => event === "task.failed").length, 1);
});

test("отмена во время повторной отправки и сразу после потери сессии завершает задачу целиком", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1", result: "ответ" });

  const { task, run } = await core.startRun({ prompt: "2", followUpOf: first.task.id });
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  assert.equal(core.manager.cancel(task.id), true);
  assert.equal(retry.request.signal.aborted, true);
  await quietPeriod();
  assert.equal(core.find(task.id)?.status, "cancelled");
  assert.equal(core.executor.runs.length, 3);
  assert.deepEqual(core.eventsOf(task.id).map(({ event }) => event), ["task.started", "task.progress", "task.cancelled"]);

  // Отмена в том же тике, что и ответ «сессия не найдена», — второй запуск не начинается.
  const { task: quick, run: quickRun } = await core.startRun({ prompt: "3", followUpOf: first.task.id });
  quickRun.push(lostSession);
  core.manager.cancel(quick.id);
  await quietPeriod();
  assert.equal(core.find(quick.id)?.status, "cancelled");
  assert.equal(core.executor.runs.length, 4);
  assert.deepEqual(core.eventsOf(quick.id).map(({ event }) => event), ["task.started", "task.cancelled"]);
});

test("без повторной отправки: обычная задача с потерянной сессией и уточнение с другой ошибкой падают сразу", async () => {
  const core = await start();
  const plain = await core.finish({ prompt: "1" }, { error: lostSession.error });
  const first = await core.finish({ prompt: "2" }, { sessionId: "s2", result: "ответ" });
  const followUp = await core.finish({ prompt: "3", followUpOf: first.task.id }, { error: { kind: "auth", message: "Not logged in" } });
  await quietPeriod();
  assert.equal(core.executor.runs.length, 3);
  assert.equal(core.find(plain.task.id)?.error?.kind, "session_not_found");
  assert.equal(core.find(followUp.task.id)?.error?.kind, "auth");
});

// --- Веб: только чтение переходит на уточнения и переживает перезапуск (LUNA-47)

const pageContext = { url: "https://github.com/o/r", title: "o/r" };

test("уточнение диалога с url у первой задачи и после события web — readOnly; чистый диалог — без него", async () => {
  const core = await start();
  const page = await core.finish({ prompt: "1", context: pageContext }, { sessionId: "s1" });
  assert.equal(page.run.request.readOnly, true);
  const { run: pageFollowUp } = await core.startRun({ prompt: "запиши всё-таки", followUpOf: page.task.id });
  assert.equal(pageFollowUp.request.readOnly, true);
  pageFollowUp.push({ type: "done", result: "нельзя" });

  // Исполнитель сам сходил в веб в задаче без контекста страницы.
  const { task: searched, run: searchRun } = await core.startRun({ prompt: "найди в вебе" });
  assert.equal("readOnly" in searchRun.request, false);
  searchRun.push({ type: "session", sessionId: "s2" });
  searchRun.push({ type: "web" });
  // Признак на диске сразу, до конца задачи.
  await until(() => core.history.get(searched.id)?.webUsed === true, "записи признака");
  assert.equal(core.find(searched.id)?.status, "running");
  searchRun.push({ type: "done", result: "нашёл" });
  await until(() => core.find(searched.id)?.status === "done", "завершения задачи");
  const { run: searchFollowUp } = await core.startRun({ prompt: "ещё", followUpOf: searched.id });
  assert.equal(searchFollowUp.request.readOnly, true);
  searchFollowUp.push({ type: "done", result: "ок" });

  const clean = await core.finish({ prompt: "чистый" }, { sessionId: "s3" });
  const { run: cleanFollowUp } = await core.startRun({ prompt: "ещё", followUpOf: clean.task.id });
  assert.equal("readOnly" in cleanFollowUp.request, false);
  cleanFollowUp.push({ type: "done", result: "ок" });
  // В протокол признак не выходит.
  assert.equal(core.manager.list().some((task) => "webUsed" in task), false);
});

test("повторная отправка переписки в заражённом диалоге — тоже readOnly, в том числе если веб был в первом запуске", async () => {
  const core = await start();
  const page = await core.finish({ prompt: "1", context: pageContext }, { sessionId: "s1", result: "ответ 1" });
  const { run } = await core.startRun({ prompt: "2", followUpOf: page.task.id });
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  assert.equal(retry.request.readOnly, true);
  retry.push({ type: "done", result: "ответ 2" });

  const clean = await core.finish({ prompt: "a" }, { sessionId: "s2", result: "ответ a" });
  const { run: cleanRun } = await core.startRun({ prompt: "b", followUpOf: clean.task.id });
  assert.equal("readOnly" in cleanRun.request, false);
  cleanRun.push({ type: "web" });
  cleanRun.push(lostSession);
  const cleanRetry = await core.nextRun(core.executor.runs.indexOf(cleanRun) + 1);
  assert.equal(cleanRetry.request.readOnly, true);
  cleanRetry.push({ type: "done", result: "ответ b" });
});

test("после перезапуска ядра: диалог с url, диалог с вебом по ходу и диалог без первой задачи — уточнения readOnly", async () => {
  const before = await start();
  const page = await before.finish({ prompt: "1", context: pageContext }, { sessionId: "s1" });

  const { task: searched, run } = await before.startRun({ prompt: "найди в вебе" });
  run.push({ type: "session", sessionId: "s2" });
  run.push({ type: "web" });
  run.push({ type: "done", result: "нашёл" });
  await until(() => before.find(searched.id)?.status === "done", "завершения задачи");

  // Первая задача с url уйдёт из истории — признак уже лежит на втором шаге диалога.
  const lostFirst = await before.finish({ prompt: "x", context: pageContext }, { sessionId: "s3" });
  const second = await before.finish({ prompt: "y", followUpOf: lostFirst.task.id }, { sessionId: "s4" });
  before.history.close();
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(join(before.dir, "history.db"));
  db.prepare("DELETE FROM tasks WHERE id = ?").run(lostFirst.task.id);
  db.close();

  const after = await start(before.dir);
  for (const [index, followUpOf] of [page.task.id, searched.id, second.task.id].entries()) {
    const { run: followUp } = await after.startRun({ prompt: "ещё", followUpOf });
    assert.equal(followUp.request.readOnly, true, `диалог №${index + 1}`);
    followUp.push({ type: "done", result: "ок" });
    await until(() => after.manager.list().every((task) => task.status !== "running"), "завершения уточнения");
  }
});

// --- Подтверждение в уточнении и повторной отправке (LUNA-49)

/** Пауза записи файла с подставным ответом. */
function writePause(target: string) {
  const answers: boolean[] = [];
  const event = {
    type: "pause" as const,
    kind: "approval" as const,
    request: { tool: "Write", kind: "write" as const, summary: "Записать файл", target },
    respond: (allow: boolean) => answers.push(allow),
  };
  return { event, answers };
}

test("уточнение задачи, просившей подтверждение: без readOnly, с уровнем своего task.submit, пауза даёт task.needs_approval; повторная отправка — так же", async () => {
  const core = await start();
  const approvalsOf = (id: string) => core.eventsOf(id).filter(({ event }) => event === "task.needs_approval");

  // Первая задача — на «правках без вопроса»; исполнитель всё равно спросил (запись вне рабочего каталога).
  const { task: first, run: firstRun } = await core.startRun({ prompt: "создай файл", permission: "edit_automatically" });
  assert.equal(firstRun.request.permission, "edit_automatically");
  firstRun.push({ type: "session", sessionId: "s1" });
  const firstPause = writePause("/work/a.txt");
  firstRun.push(firstPause.event);
  await until(() => approvalsOf(first.id).length === 1, "запроса первой задачи");
  core.manager.approve(first.id, core.find(first.id)?.approval?.id ?? "", true);
  assert.deepEqual(firstPause.answers, [true]);
  firstRun.push({ type: "done", result: "создал" });
  await until(() => core.find(first.id)?.status === "done", "завершения первой задачи");

  // Уточнение — на текущем уровне (сменили в настройках), а не на уровне первой задачи.
  const { task: followUp, run } = await core.startRun({ prompt: "допиши строку", followUpOf: first.id, permission: "manual" });
  assert.equal(run.request.permission, "manual");
  assert.equal("readOnly" in run.request, false, "с мостом и хуком");
  assert.deepEqual(run.request.resume, { sessionId: "s1" });
  const followPause = writePause("/work/a.txt");
  run.push(followPause.event);
  await until(() => approvalsOf(followUp.id).length === 1, "запроса уточнения");
  assert.equal(core.find(followUp.id)?.approval?.target, "/work/a.txt");
  core.manager.approve(followUp.id, core.find(followUp.id)?.approval?.id ?? "", true);
  assert.deepEqual(followPause.answers, [true]);

  // Сессия потерялась — переписка уходит заново тем же путём: тот же уровень, мост, пауза работает.
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  assert.equal(retry.request.permission, "manual");
  assert.equal("readOnly" in retry.request, false);
  assert.equal(retry.request.resume, undefined);
  const retryPause = writePause("/work/a.txt");
  retry.push(retryPause.event);
  await until(() => approvalsOf(followUp.id).length === 2, "запроса повторной отправки");
  assert.equal(core.find(followUp.id)?.status, "running");
  core.manager.approve(followUp.id, core.find(followUp.id)?.approval?.id ?? "", false);
  assert.deepEqual(retryPause.answers, [false]);
  retry.push({ type: "done", result: "не дописал" });
  await until(() => core.find(followUp.id)?.status === "done", "завершения уточнения");
  assert.equal(core.find(followUp.id)?.approval, undefined);
});

test("сессия потерялась, пока висел запрос: он получает отказ, повторная отправка начинает без approval", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1", result: "ответ" });
  const { task, run } = await core.startRun({ prompt: "2", followUpOf: first.task.id });
  const stale = writePause("/work/a.txt");
  run.push(stale.event);
  await until(() => core.find(task.id)?.approval !== undefined, "запроса");
  const staleId = core.find(task.id)?.approval?.id ?? "";
  run.push(lostSession);
  const retry = await core.nextRun(core.executor.runs.indexOf(run) + 1);
  assert.deepEqual(stale.answers, [false]);
  assert.equal(core.find(task.id)?.approval, undefined);
  assert.throws(() => core.manager.approve(task.id, staleId, true), /outdated|not waiting/);
  retry.push({ type: "done", result: "ок" });
  await until(() => core.find(task.id)?.status === "done", "завершения уточнения");
});
