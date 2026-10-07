import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  ALLOWED_TOOLS,
  AVAILABLE_TOOLS,
  BRIDGE_PATH,
  bridgeConfig,
  buildArgs,
  ClaudeCodeExecutor,
  PERMISSION_TOOL,
} from "../src/executors/claude-code/adapter.ts";
import { DETAIL_LIMIT } from "../src/executors/claude-code/approval.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";
import { openTestApprovals } from "./support/approvals.ts";

const fixture = (name: string) => fileURLToPath(new URL(`./fixtures/claude-code/${name}`, import.meta.url));

/** Подменный `claude`: записывает argv и stdin в файл и ведёт себя по сценарию. */
function fakeClaude(script: string): { binary: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const binary = join(dir, "claude");
  writeFileSync(
    binary,
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\ncat > "${dir}/stdin"\n${script}\n`,
  );
  chmodSync(binary, 0o755);
  return { binary, dir };
}

/**
 * Подменный `claude`, который перед ответом спрашивает разрешение так, как это делал бы мост: находит
 * сокет ядра и id запуска в `--mcp-config`, шлёт туда вызов инструмента и записывает решение в файл.
 */
function approvingClaude(call: { tool_name: string; input: Record<string, unknown> }): { binary: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const script = join(dir, "claude.mjs");
  writeFileSync(
    script,
    `
import { createConnection } from "node:net";
import { readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const argv = process.argv.slice(2);
writeFileSync(${JSON.stringify(join(dir, "argv"))}, argv.join("\\n") + "\\n");
const config = JSON.parse(argv[argv.indexOf("--mcp-config") + 1]);
const [, socketPath, runId] = config.mcpServers.luna.args;
process.stdin.resume();
process.stdout.write(readFileSync(${JSON.stringify(fixture("success.jsonl"))}, "utf8").split("\\n")[0] + "\\n");
const socket = createConnection(socketPath);
socket.setEncoding("utf8");
createInterface({ input: socket }).once("line", (line) => {
  writeFileSync(${JSON.stringify(join(dir, "decision"))}, line + "\\n");
  socket.end();
  process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "готово", session_id: "s" }) + "\\n");
  process.exit(0);
});
socket.write(JSON.stringify({ run: runId, call: ${JSON.stringify({ ...call, tool_use_id: "toolu_1" })} }) + "\\n");
`,
  );
  const binary = join(dir, "claude");
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
  chmodSync(binary, 0o755);
  return { binary, dir };
}

async function collect(executor: ClaudeCodeExecutor, signal = new AbortController().signal): Promise<ExecutorEvent[]> {
  const events: ExecutorEvent[] = [];
  for await (const event of executor.run({ prompt: "<task>\nпривет\n</task>", formatRules: "RULES", cwd: tmpdir(), signal })) {
    events.push(event);
  }
  return events;
}

/** Ведёт исполнителя до первой паузы, отвечает на неё и собирает поток до конца. */
async function collectWithApproval(
  executor: ClaudeCodeExecutor, allow: boolean, cwd = tmpdir(),
): Promise<{ events: ExecutorEvent[]; pause: Extract<ExecutorEvent, { type: "pause" }> | undefined }> {
  const events: ExecutorEvent[] = [];
  let pause: Extract<ExecutorEvent, { type: "pause" }> | undefined;
  for await (const event of executor.run({ prompt: "x", formatRules: "RULES", cwd, signal: new AbortController().signal })) {
    events.push(event);
    if (event.type === "pause") {
      pause = event;
      event.respond(allow);
    }
  }
  return { events, pause };
}

test("запускает CLI с мостом подтверждений: запись доступна, но без вопроса разрешено только чтение; промпт — через stdin", async () => {
  const approvals = await openTestApprovals();
  const { binary, dir } = fakeClaude(`cat "${fixture("success.jsonl")}"`);
  const events = await collect(new ClaudeCodeExecutor({ binary, model: "sonnet", approvals }));

  assert.equal(events.at(-1)?.type, "done");
  assert.equal(readFileSync(join(dir, "stdin"), "utf8"), "<task>\nпривет\n</task>");
  const argv = readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n");
  const mcpConfig = argv[argv.indexOf("--mcp-config") + 1] ?? "";
  const config = JSON.parse(mcpConfig) as { mcpServers: Record<string, { command: string; args: string[] }> };
  assert.deepEqual(Object.keys(config.mcpServers), ["luna"]);
  assert.equal(config.mcpServers.luna?.command, process.execPath);
  assert.equal(config.mcpServers.luna?.args[0], BRIDGE_PATH);
  assert.equal(config.mcpServers.luna?.args[1], approvals.path);
  assert.deepEqual(argv, [
    "-p",
    "--output-format", "stream-json",
    "--verbose",
    "--setting-sources", "",
    "--disable-slash-commands",
    "--strict-mcp-config",
    "--mcp-config", mcpConfig,
    "--permission-prompt-tool", "mcp__luna__approve",
    "--permission-mode", "default",
    "--tools", "WebFetch,WebSearch,Read,Glob,Grep,Write,Edit,NotebookEdit",
    "--allowedTools", "WebFetch,WebSearch,Read,Glob,Grep",
    "--append-system-prompt", "RULES",
    "--model", "sonnet",
  ]);
  assert.equal(argv.includes("--safe-mode"), false);
});

test("buildArgs: флаги уровня manual; --allowedTools без записи; с resume — те же флаги плюс --resume", () => {
  const mcpConfig = bridgeConfig("/tmp/luna.sock", "run-1");
  const plain = buildArgs({ formatRules: "RULES", model: "sonnet", mcpConfig });
  const resumed = buildArgs({ formatRules: "RULES", model: "sonnet", mcpConfig, resume: { sessionId: "6872ce2a-d1fa-476e-b60c-9c963deff778" } });
  assert.deepEqual(resumed, [...plain, "--resume", "6872ce2a-d1fa-476e-b60c-9c963deff778"]);
  assert.equal(plain.includes("--resume"), false);
  assert.equal(plain.includes("--safe-mode"), false);
  const value = (flag: string) => plain[plain.indexOf(flag) + 1];
  assert.equal(value("--setting-sources"), "");
  assert.ok(plain.includes("--disable-slash-commands"));
  assert.ok(plain.includes("--strict-mcp-config"));
  assert.equal(value("--mcp-config"), mcpConfig);
  assert.equal(value("--permission-prompt-tool"), PERMISSION_TOOL);
  assert.ok(PERMISSION_TOOL.startsWith("mcp__"));
  assert.equal(value("--permission-mode"), "default");
  assert.equal(value("--tools"), AVAILABLE_TOOLS);
  for (const tool of ["Write", "Edit", "NotebookEdit"]) assert.ok(AVAILABLE_TOOLS.split(",").includes(tool), tool);
  assert.equal(value("--allowedTools"), ALLOWED_TOOLS);
  assert.equal(ALLOWED_TOOLS, "WebFetch,WebSearch,Read,Glob,Grep");
  for (const tool of ["Write", "Edit", "NotebookEdit"]) assert.equal(ALLOWED_TOOLS.split(",").includes(tool), false, tool);
});

test("уточнение: --resume с сессией диалога уходит в CLI", async () => {
  const approvals = await openTestApprovals();
  const { binary, dir } = fakeClaude(`cat "${fixture("resume-success.jsonl")}"`);
  const events: ExecutorEvent[] = [];
  for await (const event of new ClaudeCodeExecutor({ binary, approvals }).run({
    prompt: "<task>\nкакое число?\n</task>",
    formatRules: "RULES",
    cwd: tmpdir(),
    signal: new AbortController().signal,
    resume: { sessionId: "s-1" },
  })) {
    events.push(event);
  }
  assert.equal(events.at(-1)?.type, "done");
  assert.deepEqual(readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n").slice(-2), ["--resume", "s-1"]);
});

test("без канала подтверждений исполнитель не запускается: одна понятная ошибка", async () => {
  const { binary } = fakeClaude(`cat "${fixture("success.jsonl")}"`);
  const events = await collect(new ClaudeCodeExecutor({ binary }));
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type, "failed");
  assert.match(events[0]?.type === "failed" ? events[0].error.message : "", /Канал подтверждений не открыт/);
});

test("пауза Write: событие approval с абсолютным путём и началом содержимого; разрешение возвращает вход без изменений", async () => {
  const approvals = await openTestApprovals();
  const cwd = mkdtempSync(join(tmpdir(), "luna-task-"));
  const { binary, dir } = approvingClaude({ tool_name: "Write", input: { file_path: "hello.txt", content: "hi" } });
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true, cwd);

  assert.ok(pause, "пауза не пришла");
  assert.equal(pause.kind, "approval");
  assert.equal(pause.request.tool, "Write");
  assert.equal(pause.request.kind, "write");
  assert.equal(pause.request.summary, "Записать файл");
  assert.equal(pause.request.target, join(cwd, "hello.txt"));
  assert.ok(pause.request.detail?.startsWith("hi\n"), pause.request.detail);
  assert.ok(pause.request.detail?.includes("Размер: 2 знака"), pause.request.detail);
  assert.equal(events.at(-1)?.type, "done");
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "decision"), "utf8")), {
    behavior: "allow",
    updatedInput: { file_path: "hello.txt", content: "hi" },
  });
});

test("пауза: отказ уходит мосту как deny с причиной; длинное содержимое обрезано с пометкой", async () => {
  const approvals = await openTestApprovals();
  const content = "я".repeat(DETAIL_LIMIT + 500);
  const { binary, dir } = approvingClaude({ tool_name: "Write", input: { file_path: "/abs/long.txt", content } });
  const { pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), false);

  assert.ok(pause, "пауза не пришла");
  assert.equal(pause.request.target, "/abs/long.txt");
  const detail = pause.request.detail ?? "";
  assert.ok(detail.startsWith("я".repeat(DETAIL_LIMIT)), "начало содержимого");
  assert.equal(detail.includes("я".repeat(DETAIL_LIMIT + 1)), false, "содержимое обрезано");
  assert.ok(detail.includes(`… (обрезано, всего ${DETAIL_LIMIT + 500} знаков)`), detail.slice(DETAIL_LIMIT));
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "decision"), "utf8")), {
    behavior: "deny",
    message: "Пользователь отклонил действие в Luna",
  });
});

test("пауза Edit: kind edit со старым и новым фрагментом; незнакомый инструмент — other с именем и входом", async () => {
  const approvals = await openTestApprovals();
  const edit = approvingClaude({ tool_name: "Edit", input: { file_path: "/abs/a.ts", old_string: "было", new_string: "стало" } });
  const edited = await collectWithApproval(new ClaudeCodeExecutor({ binary: edit.binary, approvals }), true);
  assert.equal(edited.pause?.request.kind, "edit");
  assert.equal(edited.pause?.request.summary, "Изменить файл");
  assert.equal(edited.pause?.request.target, "/abs/a.ts");
  assert.equal(edited.pause?.request.detail, "Заменить:\nбыло\n\nНа:\nстало");

  const other = approvingClaude({ tool_name: "Bash", input: { command: "rm -rf x", description: "удалить x" } });
  const used = await collectWithApproval(new ClaudeCodeExecutor({ binary: other.binary, approvals }), false);
  assert.equal(used.pause?.request.kind, "other");
  assert.equal(used.pause?.request.tool, "Bash");
  assert.equal(used.pause?.request.summary, "Использовать инструмент Bash");
  assert.equal(used.pause?.request.target, undefined);
  assert.equal(used.pause?.request.detail, JSON.stringify({ command: "rm -rf x", description: "удалить x" }));
});

test("сессия не найдена: одна ошибка session_not_found, без второй от кода выхода 1", async () => {
  const approvals = await openTestApprovals();
  const { binary } = fakeClaude(`cat "${fixture("session-not-found.jsonl")}"; echo "No conversation found" >&2; exit 1`);
  const events = await collect(new ClaudeCodeExecutor({ binary, approvals }));
  const failed = events.filter((event) => event.type === "failed");
  assert.equal(failed.length, 1);
  assert.equal(failed[0]?.type === "failed" && failed[0].error.kind, "session_not_found");
});

test("ненулевой код выхода после result не порождает вторую ошибку", async () => {
  const approvals = await openTestApprovals();
  const { binary } = fakeClaude(`cat "${fixture("not-logged-in.jsonl")}"; exit 1`);
  const events = await collect(new ClaudeCodeExecutor({ binary, approvals }));
  assert.deepEqual(events.filter((event) => event.type === "failed").length, 1);
  assert.deepEqual(events.at(-1), {
    type: "failed",
    error: { kind: "auth", message: "Not logged in · Please run /login" },
  });
});

test("падение CLI без result: ошибка с хвостом stderr", async () => {
  const approvals = await openTestApprovals();
  const { binary } = fakeClaude(`echo "boom" >&2; exit 3`);
  const events = await collect(new ClaudeCodeExecutor({ binary, approvals }));
  assert.deepEqual(events, [
    { type: "failed", error: { kind: "unknown", message: "Claude Code завершился без результата: boom" } },
  ]);
});

test("бинарник не найден: not_installed", async () => {
  const approvals = await openTestApprovals();
  const events = await collect(new ClaudeCodeExecutor({ binary: "/nonexistent/claude", approvals }));
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type === "failed" && events[0].error.kind, "not_installed");
});

test("отмена убивает процесс и не порождает ошибку", async () => {
  const approvals = await openTestApprovals();
  const { binary } = fakeClaude(`head -n 1 "${fixture("success.jsonl")}"; exec sleep 30`);
  const abort = new AbortController();
  const events: ExecutorEvent[] = [];
  const started = Date.now();
  for await (const event of new ClaudeCodeExecutor({ binary, approvals }).run({
    prompt: "x",
    formatRules: "RULES",
    cwd: tmpdir(),
    signal: abort.signal,
  })) {
    events.push(event);
    abort.abort();
  }
  // Первая строка потока — init: из неё идут оба события, session и model.
  assert.deepEqual(events.map((event) => event.type), ["session", "model"]);
  assert.ok(Date.now() - started < 5000, "процесс должен завершиться сразу после отмены");
});
