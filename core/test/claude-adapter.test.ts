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
  READ_ONLY_TOOLS,
} from "../src/executors/claude-code/adapter.ts";
import {
  COMMAND_LIMIT,
  COMMAND_TOO_LONG_MESSAGE,
  DENIED_MESSAGE,
  DETAIL_LIMIT,
  describeApproval,
  WEB_DENIED_MESSAGE,
} from "../src/executors/claude-code/approval.ts";
import type { ExecutorEvent, ExecutorRequest } from "../src/executors/executor.ts";
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

/** Вызов инструмента так, как его присылает мост. */
type BridgeCall = { tool_name: string; input: Record<string, unknown>; tool_use_id?: string };

/**
 * Подменный `claude`, который спрашивает разрешение так, как это делал бы мост: находит сокет ядра
 * и id запуска в `--mcp-config`, шлёт туда вызов инструмента и записывает решение в файл. Строки
 * `before` выводятся до вызова моста, `after` — после ответа. `callFirst` — вызов уходит в мост раньше
 * строк `before` (они выводятся через `delayMs`): так проверяется, что решение ждёт вывода CLI.
 */
function scriptedClaude(options: { before: string[]; call: BridgeCall; after: string[]; callFirst?: boolean; delayMs?: number }): { binary: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const script = join(dir, "claude.mjs");
  writeFileSync(
    script,
    `
import { createConnection } from "node:net";
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const argv = process.argv.slice(2);
writeFileSync(${JSON.stringify(join(dir, "argv"))}, argv.join("\\n") + "\\n");
const config = JSON.parse(argv[argv.indexOf("--mcp-config") + 1]);
const [, socketPath, runId] = config.mcpServers.luna.args;
process.stdin.resume();
const print = (lines) => { for (const line of lines) process.stdout.write(line + "\\n"); };
const before = ${JSON.stringify(options.before)};
if (${options.callFirst ? "true" : "false"}) setTimeout(() => print(before), ${options.delayMs ?? 0});
else print(before);
const socket = createConnection(socketPath);
socket.setEncoding("utf8");
createInterface({ input: socket }).once("line", (line) => {
  writeFileSync(${JSON.stringify(join(dir, "decision"))}, line + "\\n");
  socket.end();
  print(${JSON.stringify(options.after)});
  process.exit(0);
});
socket.write(JSON.stringify({ run: runId, call: ${JSON.stringify(options.call)} }) + "\\n");
`,
  );
  const binary = join(dir, "claude");
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
  chmodSync(binary, 0o755);
  return { binary, dir };
}

const fixtureLines = (name: string) => readFileSync(fixture(name), "utf8").trimEnd().split("\n");
const assistantToolUse = (id: string, name: string, input: Record<string, unknown>, parent: string | null = null) =>
  JSON.stringify({ type: "assistant", parent_tool_use_id: parent, session_id: "s", message: { content: [{ type: "tool_use", id, name, input }] } });
const RESULT = JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "готово", session_id: "s" });

/** Подменный `claude` для обычной паузы: init, строка с вызовом инструмента, вопрос мосту, результат. */
function approvingClaude(call: { tool_name: string; input: Record<string, unknown> }): { binary: string; dir: string } {
  return scriptedClaude({
    before: [fixtureLines("success.jsonl")[0] ?? "", assistantToolUse("toolu_1", call.tool_name, call.input)],
    call: { ...call, tool_use_id: "toolu_1" },
    after: [RESULT],
  });
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
  executor: ClaudeCodeExecutor, allow: boolean, cwd = tmpdir(), extra: Partial<ExecutorRequest> = {},
): Promise<{ events: ExecutorEvent[]; pause: Extract<ExecutorEvent, { type: "pause" }> | undefined }> {
  const events: ExecutorEvent[] = [];
  let pause: Extract<ExecutorEvent, { type: "pause" }> | undefined;
  for await (const event of executor.run({ prompt: "x", formatRules: "RULES", cwd, signal: new AbortController().signal, ...extra })) {
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
    "--tools", "WebFetch,WebSearch,Read,Glob,Grep,Write,Edit,NotebookEdit,Bash",
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
  for (const tool of ["Write", "Edit", "NotebookEdit", "Bash"]) assert.ok(AVAILABLE_TOOLS.split(",").includes(tool), tool);
  assert.equal(value("--allowedTools"), ALLOWED_TOOLS);
  assert.equal(ALLOWED_TOOLS, "WebFetch,WebSearch,Read,Glob,Grep");
  // Bash доступен, но не разрешён заранее: что спрашивать, решает CLI, ответ — человек через мост.
  for (const tool of ["Write", "Edit", "NotebookEdit", "Bash"]) assert.equal(ALLOWED_TOOLS.split(",").includes(tool), false, tool);
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

  const other = approvingClaude({ tool_name: "KillShell", input: { shell_id: "bash_1" } });
  const used = await collectWithApproval(new ClaudeCodeExecutor({ binary: other.binary, approvals }), false);
  assert.equal(used.pause?.request.kind, "other");
  assert.equal(used.pause?.request.tool, "KillShell");
  assert.equal(used.pause?.request.summary, "Использовать инструмент KillShell");
  assert.equal(used.pause?.request.target, undefined);
  assert.equal(used.pause?.request.detail, JSON.stringify({ shell_id: "bash_1" }));
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

// --- Только чтение и веб (LUNA-47)

/** Вызов `approve` из записанного обмена CLI с мостом. */
function bridgeCall(name: string): BridgeCall {
  for (const line of fixtureLines(name)) {
    const message = JSON.parse(line) as { method?: string; params?: { arguments?: BridgeCall } };
    if (message.method === "tools/call" && message.params?.arguments) return message.params.arguments;
  }
  throw new Error(`в ${name} нет tools/call`);
}

/** Строки вывода CLI до строки с вызовом `toolUseId` включительно и после неё. */
function splitAt(lines: string[], toolUseId: string): { before: string[]; after: string[] } {
  const at = lines.findIndex((line) => line.includes(`"id":"${toolUseId}"`));
  assert.ok(at >= 0, `строка с ${toolUseId}`);
  return { before: lines.slice(0, at + 1), after: lines.slice(at + 1) };
}

const decisionOf = (dir: string) => JSON.parse(readFileSync(join(dir, "decision"), "utf8")) as unknown;
const argvOf = (dir: string) => readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n");
const toolsOf = (argv: string[]) => new Set((argv[argv.indexOf("--tools") + 1] ?? "").split(","));

test("buildArgs readOnly: --tools — ровно перечень чтения, без моста и --permission-prompt-tool; изоляция та же; с resume — плюс --resume", () => {
  const plain = buildArgs({ formatRules: "RULES", model: "sonnet", readOnly: true });
  const resumed = buildArgs({ formatRules: "RULES", model: "sonnet", readOnly: true, resume: { sessionId: "s-1" } });
  assert.deepEqual(resumed, [...plain, "--resume", "s-1"]);
  assert.deepEqual(toolsOf(plain), new Set(["WebFetch", "WebSearch", "Read", "Glob", "Grep"]));
  assert.equal(READ_ONLY_TOOLS, "WebFetch,WebSearch,Read,Glob,Grep");
  for (const tool of ["Write", "Edit", "NotebookEdit", "Bash"]) assert.equal(toolsOf(plain).has(tool), false, tool);
  assert.equal(plain.includes("--permission-prompt-tool"), false);
  assert.equal(plain.includes("--mcp-config"), false);
  assert.equal(plain.some((arg) => arg.includes(PERMISSION_TOOL)), false);
  const value = (flag: string) => plain[plain.indexOf(flag) + 1];
  assert.equal(value("--permission-mode"), "default");
  assert.equal(value("--setting-sources"), "");
  assert.ok(plain.includes("--disable-slash-commands"));
  assert.ok(plain.includes("--strict-mcp-config"));
  assert.equal(value("--append-system-prompt"), "RULES");
  assert.equal(value("--model"), "sonnet");
});

test("запуск readOnly: без канала подтверждений доходит до done, в CLI — только чтение и ни моста, ни --permission-prompt-tool", async () => {
  const { binary, dir } = fakeClaude(`cat "${fixture("success.jsonl")}"`);
  const events: ExecutorEvent[] = [];
  for await (const event of new ClaudeCodeExecutor({ binary }).run({
    prompt: "x", formatRules: "RULES", cwd: tmpdir(), signal: new AbortController().signal, readOnly: true,
  })) events.push(event);
  assert.equal(events.at(-1)?.type, "done");
  const argv = argvOf(dir);
  assert.deepEqual(toolsOf(argv), new Set(READ_ONLY_TOOLS.split(",")));
  assert.equal(argv.includes("--mcp-config"), false);
  assert.equal(argv.includes("--permission-prompt-tool"), false);
  assert.equal(argv[argv.indexOf("--permission-mode") + 1], "default");
});

test("запуск readOnly с открытым каналом: мост всё равно не подключается", async () => {
  const approvals = await openTestApprovals();
  const { binary, dir } = fakeClaude(`cat "${fixture("success.jsonl")}"`);
  const events: ExecutorEvent[] = [];
  for await (const event of new ClaudeCodeExecutor({ binary, approvals }).run({
    prompt: "x", formatRules: "RULES", cwd: tmpdir(), signal: new AbortController().signal, readOnly: true, resume: { sessionId: "s-1" },
  })) events.push(event);
  assert.equal(events.at(-1)?.type, "done");
  const argv = argvOf(dir);
  assert.equal(argv.includes("--mcp-config"), false);
  assert.equal(argv.includes("--permission-prompt-tool"), false);
  assert.deepEqual(toolsOf(argv), new Set(READ_ONLY_TOOLS.split(",")));
  assert.deepEqual(argv.slice(-2), ["--resume", "s-1"]);
});

test("веб, затем запись (живой поток sonnet): мост получает deny про веб, паузы нет, исполнитель сообщает о вебе", async () => {
  const approvals = await openTestApprovals();
  const call = bridgeCall("web-then-write.bridge.jsonl");
  assert.equal(call.tool_name, "Write");
  const { before, after } = splitAt(fixtureLines("web-then-write.jsonl"), call.tool_use_id ?? "");
  const { binary, dir } = scriptedClaude({ before, call, after });
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true);

  assert.equal(pause, undefined, "запрос не должен дойти до человека");
  assert.deepEqual(decisionOf(dir), { behavior: "deny", message: WEB_DENIED_MESSAGE });
  assert.equal(events.filter((event) => event.type === "web").length, 1);
  // Событие о вебе приходит раньше итога.
  assert.ok(events.findIndex((event) => event.type === "web") < events.findIndex((event) => event.type === "done"));
  assert.equal(events.at(-1)?.type, "done");
});

test("WebFetch в основной сессии и WebSearch у субагента (синтетика): запись после них отклоняется без человека", async () => {
  const approvals = await openTestApprovals();
  const init = fixtureLines("success.jsonl")[0] ?? "";
  const write = { file_path: "/abs/x.txt", content: "x" };
  for (const web of [
    assistantToolUse("toolu_w", "WebFetch", { url: "https://example.com" }),
    assistantToolUse("toolu_w", "WebSearch", { query: "rfc 2119" }, "toolu_agent"),
  ]) {
    const { binary, dir } = scriptedClaude({
      before: [init, web, assistantToolUse("toolu_2", "Write", write)],
      call: { tool_name: "Write", input: write, tool_use_id: "toolu_2" },
      after: [RESULT],
    });
    const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true);
    assert.equal(pause, undefined);
    assert.deepEqual(decisionOf(dir), { behavior: "deny", message: WEB_DENIED_MESSAGE });
    assert.equal(events.filter((event) => event.type === "web").length, 1);
  }
});

test("вызов моста пришёл раньше строки вывода: решение ждёт её и видит веб", async () => {
  const approvals = await openTestApprovals();
  const init = fixtureLines("success.jsonl")[0] ?? "";
  const write = { file_path: "/abs/x.txt", content: "x" };
  const { binary, dir } = scriptedClaude({
    before: [init, assistantToolUse("toolu_w", "WebFetch", { url: "https://example.com" }), assistantToolUse("toolu_2", "Write", write)],
    call: { tool_name: "Write", input: write, tool_use_id: "toolu_2" },
    after: [RESULT],
    callFirst: true,
    delayMs: 100,
  });
  const { pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true);
  assert.equal(pause, undefined);
  assert.deepEqual(decisionOf(dir), { behavior: "deny", message: WEB_DENIED_MESSAGE });
});

test("строка вызова так и не появилась: отказ без человека, задача не висит", async () => {
  const approvals = await openTestApprovals();
  const { binary, dir } = scriptedClaude({
    before: [fixtureLines("success.jsonl")[0] ?? ""],
    call: { tool_name: "Write", input: { file_path: "/abs/x.txt", content: "x" }, tool_use_id: "toolu_missing" },
    after: [RESULT],
  });
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals, toolUseWaitMs: 50 }), true);
  assert.equal(pause, undefined);
  assert.equal((decisionOf(dir) as { behavior: string }).behavior, "deny");
  assert.equal(events.at(-1)?.type, "done");
});

test("вызов моста без веба (обмен approval-allow): пауза приходит как раньше, события о вебе нет", async () => {
  const approvals = await openTestApprovals();
  const call = bridgeCall("approval-allow.jsonl");
  const { binary, dir } = scriptedClaude({
    before: [fixtureLines("success.jsonl")[0] ?? "", assistantToolUse(call.tool_use_id ?? "", call.tool_name, call.input)],
    call,
    after: [RESULT],
    callFirst: true,
    delayMs: 50,
  });
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true);
  assert.ok(pause, "пауза не пришла");
  assert.equal(pause.request.tool, "Write");
  assert.equal(events.some((event) => event.type === "web"), false);
  assert.equal((decisionOf(dir) as { behavior: string }).behavior, "allow");
});

// --- Команды shell (LUNA-48)

test("Bash (живой поток sonnet): пауза shell, target — команда как есть, подпись агента — отдельной строкой в detail; разрешение возвращает вход без изменений", async () => {
  const approvals = await openTestApprovals();
  const call = bridgeCall("approval-bash.bridge.jsonl");
  assert.equal(call.tool_name, "Bash");
  const command = call.input.command;
  const description = call.input.description;
  assert.ok(typeof command === "string" && command.includes("\n"), "команда в фикстуре многострочная");
  assert.ok(typeof description === "string" && description !== command, "подпись агента отличается от команды");
  const { before, after } = splitAt(fixtureLines("approval-bash.jsonl"), call.tool_use_id ?? "");
  const { binary, dir } = scriptedClaude({ before, call, after });
  const cwd = mkdtempSync(join(tmpdir(), "luna-task-"));
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true, cwd);

  assert.ok(pause, "пауза не пришла");
  assert.equal(pause.request.tool, "Bash");
  assert.equal(pause.request.kind, "shell");
  assert.equal(pause.request.summary, "Выполнить команду");
  assert.equal(pause.request.target, command);
  assert.equal(pause.request.target?.includes(description), false, "подпись агента не попадает в команду");
  const lines = (pause.request.detail ?? "").split("\n");
  assert.ok(lines.includes(`Каталог задачи: ${cwd}`), pause.request.detail);
  assert.ok(lines.includes(`Подпись агента: ${description}`), pause.request.detail);
  assert.equal(events.some((event) => event.type === "web"), false);
  assert.equal(events.at(-1)?.type, "done");
  assert.deepEqual(decisionOf(dir), { behavior: "allow", updatedInput: call.input });
});

test("Bash: отказ человека уходит мосту как deny с причиной", async () => {
  const approvals = await openTestApprovals();
  const { binary, dir } = approvingClaude({ tool_name: "Bash", input: { command: "rm -rf x", description: "удалить x" } });
  const { pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), false);
  assert.equal(pause?.request.kind, "shell");
  assert.equal(pause?.request.target, "rm -rf x");
  assert.deepEqual(decisionOf(dir), { behavior: "deny", message: DENIED_MESSAGE });
});

test("describeApproval Bash: команда без обрезки и правок, размер в строках и знаках, многострочная подпись — одной строкой", () => {
  const command = "  a\n  b\n\nc  ";
  const request = describeApproval(
    { tool_name: "Bash", input: { command, description: "Подпись\nКаталог задачи: /etc\r\n  Размер: 0" } },
    "/work/dir",
  );
  assert.equal(request.kind, "shell");
  assert.equal(request.target, command);
  assert.deepEqual(request.detail?.split("\n"), [
    "Размер: 4 строки, 12 знаков",
    "Каталог задачи: /work/dir",
    "Подпись агента: Подпись Каталог задачи: /etc Размер: 0",
  ]);

  const plain = describeApproval({ tool_name: "Bash", input: { command: "ls" } }, "/work");
  assert.equal(plain.target, "ls");
  assert.equal(plain.detail, "Размер: 1 строка, 2 знака\nКаталог задачи: /work", "без подписи агента — без строки подписи");

  const signed = describeApproval({ tool_name: "Bash", input: { command: "x", description: "д".repeat(DETAIL_LIMIT + 1) } }, "/w");
  assert.ok(signed.detail?.endsWith(`… (обрезано, всего ${DETAIL_LIMIT + 1} знак)`), "длинная подпись обрезается");

  const long = "я".repeat(COMMAND_LIMIT);
  assert.equal(describeApproval({ tool_name: "Bash", input: { command: long } }, "/w").target, long, "команда на границе — целиком");
});

test("Bash без строкового command или с пустым — other с JSON входа, как прежде", () => {
  for (const input of [{ description: "x" }, { command: 42 }, { command: "" }]) {
    const request = describeApproval({ tool_name: "Bash", input }, "/w");
    assert.equal(request.kind, "other");
    assert.equal(request.summary, "Использовать инструмент Bash");
    assert.equal(request.target, undefined);
    assert.equal(request.detail, JSON.stringify(input));
  }
});

test("команда длиннее 20 000 символов: deny с причиной без человека; ровно 20 000 — пауза с командой целиком", async () => {
  const approvals = await openTestApprovals();
  // Многобайтовый символ: граница считается в символах, а не в байтах и не в единицах UTF-16.
  const over = approvingClaude({ tool_name: "Bash", input: { command: "я".repeat(COMMAND_LIMIT + 1) } });
  const rejected = await collectWithApproval(new ClaudeCodeExecutor({ binary: over.binary, approvals }), true);
  assert.equal(rejected.pause, undefined, "запрос не должен дойти до человека");
  assert.deepEqual(decisionOf(over.dir), { behavior: "deny", message: COMMAND_TOO_LONG_MESSAGE });
  assert.equal(rejected.events.at(-1)?.type, "done");

  const emoji = approvingClaude({ tool_name: "Bash", input: { command: "😀".repeat(COMMAND_LIMIT) } });
  const shown = await collectWithApproval(new ClaudeCodeExecutor({ binary: emoji.binary, approvals }), true);
  assert.ok(shown.pause, "на границе запрос уходит человеку");
  assert.equal([...(shown.pause.request.target ?? "")].length, COMMAND_LIMIT);
  assert.equal(shown.pause.request.target, "😀".repeat(COMMAND_LIMIT));
  assert.equal((decisionOf(emoji.dir) as { behavior: string }).behavior, "allow");

  const exact = approvingClaude({ tool_name: "Bash", input: { command: "я".repeat(COMMAND_LIMIT) } });
  const atLimit = await collectWithApproval(new ClaudeCodeExecutor({ binary: exact.binary, approvals }), false);
  assert.equal(atLimit.pause?.request.target, "я".repeat(COMMAND_LIMIT));
});

test("Bash после веба: deny про веб, паузы нет — тем же путём, что запись", async () => {
  const approvals = await openTestApprovals();
  const init = fixtureLines("success.jsonl")[0] ?? "";
  const bash = { command: "python3 -c \"open('x','w')\"", description: "создать x" };
  const { binary, dir } = scriptedClaude({
    before: [init, assistantToolUse("toolu_w", "WebSearch", { query: "rfc 2119" }), assistantToolUse("toolu_2", "Bash", bash)],
    call: { tool_name: "Bash", input: bash, tool_use_id: "toolu_2" },
    after: [RESULT],
  });
  const { events, pause } = await collectWithApproval(new ClaudeCodeExecutor({ binary, approvals }), true);
  assert.equal(pause, undefined);
  assert.deepEqual(decisionOf(dir), { behavior: "deny", message: WEB_DENIED_MESSAGE });
  assert.equal(events.filter((event) => event.type === "web").length, 1);
});
