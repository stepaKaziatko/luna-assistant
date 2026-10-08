import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  ALLOWED_TOOLS,
  BRIDGE_PATH,
  bridgeConfig,
  buildArgs,
  childEnv,
  ClaudeCodeExecutor,
  hookSettings,
  PERMISSION_MODES,
  PERMISSION_TOOL,
  READ_ONLY_TOOLS,
} from "../src/executors/claude-code/adapter.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";
import type { PermissionLevel, TaskInfo } from "../src/rpc/protocol.gen.ts";
import { DEFAULT_PERMISSION, PermissionError, TaskManager, type TaskEventName } from "../src/tasks/manager.ts";
import { isPermissionLevel } from "../src/tasks/permission.ts";
import { openTestApprovals } from "./support/approvals.ts";
import { ManualExecutor } from "./support/manual-executor.ts";
import { nextRun, until } from "./support/wait.ts";

// Уровни разрешений (LUNA-52): отображение уровня в флаги Claude Code и путь уровня через ядро.

const fixture = (name: string) => fileURLToPath(new URL(`./fixtures/claude-code/${name}`, import.meta.url));
const LEVELS: PermissionLevel[] = ["manual", "edit_automatically"];
const WRITE_AND_SHELL = ["Write", "Edit", "NotebookEdit", "Bash"];

/** Подменный `claude`: argv и окружение — в файлы, вывод — записанный успешный поток. */
function fakeClaude(): { binary: string; argv: () => string[]; env: () => string } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const binary = join(dir, "claude");
  writeFileSync(binary, `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\nenv > "${dir}/env"\ncat > /dev/null\ncat "${fixture("success.jsonl")}"\n`);
  chmodSync(binary, 0o755);
  return {
    binary,
    argv: () => readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n"),
    env: () => readFileSync(join(dir, "env"), "utf8"),
  };
}

async function run(executor: ClaudeCodeExecutor, permission: PermissionLevel, readOnly = false): Promise<ExecutorEvent[]> {
  const events: ExecutorEvent[] = [];
  for await (const event of executor.run({
    prompt: "x", formatRules: "RULES", cwd: tmpdir(), signal: new AbortController().signal, permission, ...(readOnly ? { readOnly } : {}),
  })) events.push(event);
  return events;
}

const valueOf = (argv: string[], flag: string) => argv[argv.indexOf(flag) + 1];
const toolsOf = (argv: string[]) => new Set((valueOf(argv, "--tools") ?? "").split(","));

// --- Адаптер Claude Code

test("buildArgs по уровням: manual → default без --add-dir, edit_automatically → acceptEdits и --add-dir домашнего каталога; остальное одинаково", () => {
  const mcpConfig = bridgeConfig("/tmp/luna.sock", "run-1");
  const settings = hookSettings("/tmp/luna.sock", "run-1");
  const argsOf = (permission: PermissionLevel) => buildArgs({ formatRules: "RULES", model: "sonnet", permission, mcpConfig, settings });

  const manual = argsOf("manual");
  assert.equal(valueOf(manual, "--permission-mode"), "default");
  assert.equal(manual.includes("--add-dir"), false);

  const edit = argsOf("edit_automatically");
  assert.equal(valueOf(edit, "--permission-mode"), "acceptEdits");
  assert.equal(valueOf(edit, "--add-dir"), homedir());
  // Каталог задаётся вызывающим (в запуске — домашний).
  assert.equal(valueOf(buildArgs({ formatRules: "R", permission: "edit_automatically", mcpConfig, settings, addDir: "/tmp/x" }), "--add-dir"), "/tmp/x");

  for (const [permission, argv] of [["manual", manual], ["edit_automatically", edit]] as const) {
    assert.equal(valueOf(argv, "--allowedTools"), "WebFetch,WebSearch,Read,Glob,Grep", permission);
    assert.equal(valueOf(argv, "--allowedTools"), ALLOWED_TOOLS);
    for (const tool of WRITE_AND_SHELL) assert.ok(toolsOf(argv).has(tool), `${permission}: ${tool} доступен`);
    assert.equal(argv.includes("--safe-mode"), false);
    assert.equal(argv.includes("--dangerously-skip-permissions"), false);
    assert.equal(argv.includes("--allow-dangerously-skip-permissions"), false);
    assert.equal(valueOf(argv, "--setting-sources"), "");
    assert.ok(argv.includes("--strict-mcp-config"));
    assert.ok(argv.includes("--disable-slash-commands"));
    assert.equal(valueOf(argv, "--mcp-config"), mcpConfig);
    assert.equal(valueOf(argv, "--permission-prompt-tool"), PERMISSION_TOOL);
    // Хук веб-запрета — на каждом уровне.
    const hook = JSON.parse(valueOf(argv, "--settings") ?? "{}") as { hooks: { PreToolUse: { matcher: string; hooks: { command: string; timeout?: number }[] }[] } };
    assert.equal(hook.hooks.PreToolUse[0]?.matcher, "Write|Edit|NotebookEdit|Bash");
    const command = hook.hooks.PreToolUse[0]?.hooks[0]?.command ?? "";
    assert.ok(command.includes(BRIDGE_PATH) && command.includes("'hook'"), command);
    assert.equal(typeof hook.hooks.PreToolUse[0]?.hooks[0]?.timeout, "number");
  }
  // Кроме режима и --add-dir, флаги уровней совпадают.
  assert.deepEqual(edit.filter((arg) => arg !== "--add-dir" && arg !== homedir() && arg !== "acceptEdits"), manual.filter((arg) => arg !== "default"));
});

test("набор уровней Claude Code — manual и edit_automatically; полного доступа нет ни в таблице, ни во флагах", () => {
  assert.deepEqual(Object.keys(PERMISSION_MODES), ["manual", "edit_automatically"]);
  assert.deepEqual(new ClaudeCodeExecutor().permissionLevels, ["manual", "edit_automatically"]);
  assert.equal(Object.values(PERMISSION_MODES).includes("bypassPermissions"), false);
  for (const level of ["full_access", "bogus", "", 42, null, "MANUAL"]) assert.equal(isPermissionLevel(level), false, String(level));
  for (const level of LEVELS) assert.equal(isPermissionLevel(level), true, level);
});

test("readOnly на любом уровне: в CLI только чтение, режим default, ни моста, ни хука, ни --add-dir", async () => {
  const approvals = await openTestApprovals();
  for (const permission of LEVELS) {
    const claude = fakeClaude();
    const events = await run(new ClaudeCodeExecutor({ binary: claude.binary, approvals }), permission, true);
    assert.equal(events.at(-1)?.type, "done", permission);
    const argv = claude.argv();
    assert.deepEqual(toolsOf(argv), new Set(READ_ONLY_TOOLS.split(",")), permission);
    for (const tool of WRITE_AND_SHELL) assert.equal(toolsOf(argv).has(tool), false, `${permission}: ${tool}`);
    assert.equal(valueOf(argv, "--permission-mode"), "default", permission);
    for (const flag of ["--permission-prompt-tool", "--mcp-config", "--settings", "--add-dir"]) assert.equal(argv.includes(flag), false, `${permission}: ${flag}`);
  }
});

test("запуск по уровню: режим в argv; в окружении CLI нет CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD и маркеров родительской сессии", async () => {
  const approvals = await openTestApprovals();
  const saved = process.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD;
  process.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = "1";
  try {
    for (const permission of LEVELS) {
      const claude = fakeClaude();
      const events = await run(new ClaudeCodeExecutor({ binary: claude.binary, approvals }), permission);
      assert.equal(events.at(-1)?.type, "done", permission);
      assert.equal(valueOf(claude.argv(), "--permission-mode"), PERMISSION_MODES[permission]);
      assert.equal(/^CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=/m.test(claude.env()), false, permission);
    }
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD;
    else process.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = saved;
  }
  const env = childEnv({ PATH: "/bin", CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: "1", CLAUDECODE: "1", HOME: "/Users/x" });
  assert.deepEqual(env, { PATH: "/bin", HOME: "/Users/x" });
});

test("уровень, которого исполнитель не объявил, — ошибка без запуска CLI, а не подмена", async () => {
  const approvals = await openTestApprovals();
  const claude = fakeClaude();
  const events = await run(new ClaudeCodeExecutor({ binary: claude.binary, approvals }), "full_access" as PermissionLevel);
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type, "failed");
  assert.throws(() => claude.argv(), "CLI не запускался");
});

test("status: permissionLevels есть и у установленного CLI, и у ненайденного", async () => {
  const claude = fakeClaude();
  assert.deepEqual((await new ClaudeCodeExecutor({ binary: claude.binary }).status()).permissionLevels, LEVELS);
  const missing = await new ClaudeCodeExecutor({ binary: join(tmpdir(), "luna-no-such-claude") }).status();
  assert.equal(missing.available, false);
  assert.deepEqual(missing.permissionLevels, LEVELS);
});

// --- Менеджер задач

function setup(executor = new ManualExecutor()) {
  const events: { event: TaskEventName; task: TaskInfo }[] = [];
  const manager = new TaskManager({
    executors: [executor],
    defaultExecutor: "claude-code",
    tasksDir: mkdtempSync(join(tmpdir(), "luna-tasks-")),
    emit: (event, task) => events.push({ event, task }),
  });
  const finished = (id: string) => until(() => events.some(({ event, task }) => task.id === id && event !== "task.started" && event !== "task.progress" && event !== "task.needs_approval"), "завершения задачи");
  return { executor, events, manager, finished };
}

test("менеджер: permission из task.submit доходит до исполнителя, без него — manual; в TaskInfo уровня нет", async () => {
  const { executor, manager, finished } = setup();
  const edit = manager.submit({ prompt: "1", permission: "edit_automatically" });
  assert.equal("permission" in edit, false);
  const first = await nextRun(executor, 0);
  assert.equal(first.request.permission, "edit_automatically");
  assert.equal(first.request.readOnly, undefined);
  first.push({ type: "done", result: "ok" });
  await finished(edit.id);

  const plain = manager.submit({ prompt: "2" });
  const second = await nextRun(executor, 1);
  assert.equal(second.request.permission, "manual");
  assert.equal(DEFAULT_PERMISSION, "manual");
  second.push({ type: "done", result: "ok" });
  await finished(plain.id);
});

test("менеджер: уровень, которого исполнитель не объявил, — PermissionError, задача не создаётся", () => {
  const { executor, manager } = setup(new ManualExecutor(["manual"]));
  assert.throws(() => manager.submit({ prompt: "x", permission: "edit_automatically" }), PermissionError);
  assert.equal(manager.list().length, 0);
  assert.equal(executor.runs.length, 0);
});

test("менеджер: уточнение несёт свой уровень, а не уровень исходной задачи; повторная отправка переписки — с тем же уровнем", async () => {
  const { executor, manager, finished } = setup();
  const base = manager.submit({ prompt: "основа", permission: "edit_automatically" });
  const first = await nextRun(executor, 0);
  first.push({ type: "session", sessionId: "s1" });
  first.push({ type: "done", result: "ответ" });
  await finished(base.id);

  // Без уровня уточнение идёт на manual, хотя основа была на edit_automatically.
  const manualFollowUp = manager.submit({ prompt: "ещё", followUpOf: base.id });
  const second = await nextRun(executor, 1);
  assert.equal(second.request.permission, "manual");
  second.push({ type: "session", sessionId: "s2" });
  second.push({ type: "done", result: "ещё ответ" });
  await finished(manualFollowUp.id);

  // Уточнение на edit_automatically; сессия потеряна — переписка уходит заново на том же уровне.
  const editFollowUp = manager.submit({ prompt: "и ещё", followUpOf: manualFollowUp.id, permission: "edit_automatically" });
  const third = await nextRun(executor, 2);
  assert.equal(third.request.permission, "edit_automatically");
  assert.deepEqual(third.request.resume, { sessionId: "s2" });
  third.push({ type: "failed", error: { kind: "session_not_found", message: "нет" } });
  const resend = await nextRun(executor, 3);
  assert.equal(resend.request.resume, undefined);
  assert.equal(resend.request.permission, "edit_automatically");
  resend.push({ type: "done", result: "ok" });
  await finished(editFollowUp.id);

  // Уточнение к диалогу исполнителя, который уровня не объявил, — отказ.
  const strict = setup(new ManualExecutor(["manual"]));
  const only = strict.manager.submit({ prompt: "x" });
  const run0 = await nextRun(strict.executor, 0);
  run0.push({ type: "session", sessionId: "s" });
  run0.push({ type: "done", result: "ok" });
  await strict.finished(only.id);
  assert.throws(() => strict.manager.submit({ prompt: "y", followUpOf: only.id, permission: "edit_automatically" }), PermissionError);
});

test("менеджер: диалог с url или после веба идёт readOnly на любом уровне; уровень при этом передаётся как есть", async () => {
  for (const permission of LEVELS) {
    const { executor, manager, finished } = setup();
    const web = manager.submit({ prompt: "страница", context: { url: "https://example.com" }, permission });
    const first = await nextRun(executor, 0);
    assert.equal(first.request.readOnly, true, permission);
    assert.equal(first.request.permission, permission);
    first.push({ type: "done", result: "ok" });
    await finished(web.id);

    // Без url, но исполнитель сходил в веб: уточнение диалога — тоже только чтение.
    const plain = manager.submit({ prompt: "без страницы", permission });
    const second = await nextRun(executor, 1);
    assert.equal(second.request.readOnly, undefined, permission);
    second.push({ type: "session", sessionId: "s" });
    second.push({ type: "web" });
    second.push({ type: "done", result: "ok" });
    await finished(plain.id);
    const followUp = manager.submit({ prompt: "запиши", followUpOf: plain.id, permission });
    const third = await nextRun(executor, 2);
    assert.equal(third.request.readOnly, true, permission);
    third.push({ type: "done", result: "ok" });
    await finished(followUp.id);
  }
});
