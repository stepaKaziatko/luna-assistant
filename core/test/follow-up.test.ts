import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { FORMAT_RULES } from "../src/prompt/build.ts";
import type { TaskError, TaskInfo, TaskSubmitParams } from "../src/rpc/protocol.gen.ts";
import { openHistory } from "../src/tasks/history.ts";
import { FollowUpError, TaskManager } from "../src/tasks/manager.ts";
import { ManualExecutor } from "./support/manual-executor.ts";

const quiet = () => {};
const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

/** Ядро на каталоге данных, как в main.ts: история на диске и менеджер поверх неё. */
async function start(dir = mkdtempSync(join(tmpdir(), "luna-data-"))) {
  const history = await openHistory(dir, { log: quiet });
  assert.ok(history, "история открылась");
  const executor = new ManualExecutor();
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: join(dir, "tasks"),
    history,
    emit: quiet,
  });

  /** Отправляет задачу и проводит её запуск до конца: сессия и результат либо ошибка. */
  const finish = async (
    params: TaskSubmitParams,
    outcome: { sessionId?: string; result?: string; error?: TaskError } = {},
  ) => {
    const task = manager.submit(params);
    await settle();
    const run = executor.runs.at(-1);
    assert.ok(run, "исполнитель запущен");
    if (outcome.sessionId) run.push({ type: "session", sessionId: outcome.sessionId });
    run.push(outcome.error ? { type: "failed", error: outcome.error } : { type: "done", result: outcome.result ?? "ok" });
    await settle();
    return { task, run };
  };

  const find = (id: string) => manager.list().find((task) => task.id === id);
  return { dir, history, executor, manager, finish, find };
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
  await settle();

  const run = core.executor.runs[1];
  assert.ok(run);
  assert.equal(run.request.prompt, "<task>\nа покороче?\n</task>");
  assert.equal(run.request.formatRules, FORMAT_RULES);
  assert.equal(run.request.cwd, first.run.request.cwd);
  assert.deepEqual(run.request.resume, { sessionId: "s1" });
  assert.equal(first.run.request.resume, undefined, "обычная задача сессию не продолжает");

  // sessionId уточнения — из его собственного потока.
  run.push({ type: "session", sessionId: "s2" });
  run.push({ type: "done", result: "коротко" });
  await settle();
  assert.equal(core.find(followUp.id)?.sessionId, "s2");
  assert.equal(core.history.get(followUp.id)?.workdir, first.run.request.cwd);

  // Цепочка из трёх: threadId — id первой задачи, сессия — последнего ответа.
  const third = core.manager.submit({ prompt: "ещё короче", followUpOf: followUp.id });
  await settle();
  assert.equal(third.threadId, first.task.id);
  assert.deepEqual(core.executor.runs[2]?.request.resume, { sessionId: "s2" });
  assert.equal(core.executor.runs[2]?.request.cwd, first.run.request.cwd);
});

test("удалённая очисткой директория создаётся заново по тому же пути", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "x" }, { sessionId: "s1" });
  const cwd = first.run.request.cwd;
  rmSync(cwd, { recursive: true, force: true });
  assert.equal(existsSync(cwd), false);

  const followUp = core.manager.submit({ prompt: "y", followUpOf: first.task.id });
  await settle();
  assert.equal(core.executor.runs[1]?.request.cwd, cwd);
  assert.equal(existsSync(cwd), true);
  assert.equal(core.history.get(followUp.id)?.workdir, cwd);
});

test("followUpOf отклоняется: задачи нет, не done, без сессии, не последний ответ, диалог активен, сессия потеряна", async () => {
  const core = await start();
  rejects(core.manager, "missing");

  const failed = await core.finish({ prompt: "f" }, { sessionId: "sf", error: { kind: "auth", message: "Not logged in" } });
  rejects(core.manager, failed.task.id);

  const cancelled = core.manager.submit({ prompt: "c" });
  await settle();
  core.manager.cancel(cancelled.id);
  rejects(core.manager, cancelled.id);

  const running = core.manager.submit({ prompt: "r" });
  await settle();
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
  const pending = core.manager.submit({ prompt: "a2", followUpOf: active.task.id });
  rejects(core.manager, active.task.id);
  await settle();
  rejects(core.manager, active.task.id);
  core.manager.cancel(pending.id);

  // Сессия у исполнителя потеряна — до LUNA-25 диалог не продолжается.
  const lost = await core.finish({ prompt: "l" }, { sessionId: "sl" });
  await core.finish(
    { prompt: "l2", followUpOf: lost.task.id },
    { error: { kind: "session_not_found", message: "нет сессии" } },
  );
  rejects(core.manager, lost.task.id);
});

test("неудачное или отменённое уточнение не закрывает диалог: продолжение — от последнего ответа", async () => {
  const core = await start();
  const first = await core.finish({ prompt: "1" }, { sessionId: "s1" });
  await core.finish(
    { prompt: "2", followUpOf: first.task.id },
    { error: { kind: "rate_limit", message: "лимит" } },
  );
  const cancelled = core.manager.submit({ prompt: "3", followUpOf: first.task.id });
  await settle();
  core.manager.cancel(cancelled.id);
  await settle();

  const accepted = core.manager.submit({ prompt: "4", followUpOf: first.task.id });
  assert.equal(accepted.threadId, first.task.id);
  await settle();
  assert.deepEqual(core.executor.runs.at(-1)?.request.resume, { sessionId: "s1" });
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
  await settle();
  const run = after.executor.runs[0];
  assert.equal(run?.request.cwd, first.run.request.cwd);
  assert.deepEqual(run?.request.resume, { sessionId: "s2" });
  rejects(after.manager, first.task.id);

  run?.push({ type: "done", result: "417" });
  await settle();
  assert.deepEqual(
    after.history.thread(first.task.id).map(({ task }) => [task.id, task.threadId]),
    [first.task.id, second.task.id, followUp.id].map((id) => [id, first.task.id]),
  );
});

test("history.db версии 1 переходит на версию 2 без потери задач", async () => {
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
  assert.deepEqual({ ...(check.prepare("PRAGMA user_version").get() as object) }, { user_version: 2 });
  check.close();
});
