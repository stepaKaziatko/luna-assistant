import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BRIDGE_PATH, ClaudeCodeExecutor, HOOK_MATCHER, HOOK_TIMEOUT_S, hookSettings } from "../src/executors/claude-code/adapter.ts";
import { WEB_DENIED_MESSAGE } from "../src/executors/claude-code/approval.ts";
import type { BridgeRequest } from "../src/executors/claude-code/socket.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";
import type { PermissionLevel } from "../src/rpc/protocol.gen.ts";
import { openTestApprovals } from "./support/approvals.ts";

// Хук `PreToolUse` (LUNA-52): режим `hook` моста и его решение в ядре. Вход хука — записанный stdin
// реального запуска Claude Code 2.1.181 (`*.hook.jsonl`, см. fixtures/claude-code/README.md).

const fixturePath = (name: string) => fileURLToPath(new URL(`./fixtures/claude-code/${name}`, import.meta.url));
const fixtureLines = (name: string) => readFileSync(fixturePath(name), "utf8").trimEnd().split("\n");

interface HookInput {
  tool_name: string;
  tool_input: Record<string, unknown>;
  tool_use_id: string;
  hook_event_name: string;
}
const hookInputs = (name: string) => fixtureLines(name).map((line) => JSON.parse(line) as HookInput);

interface HookRun {
  code: number | null;
  stdout: string;
  stderr: string;
}

/** Хук дочерним процессом, как его запускает CLI: вход — в stdin, решение — в stdout и коде выхода. */
async function runHook(socketPath: string, input: string, run = "run-1"): Promise<HookRun> {
  const child = spawn(process.execPath, [BRIDGE_PATH, "hook", socketPath, run], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
  child.stdin.end(input);
  const code = await new Promise<number | null>((resolve) => child.once("close", resolve));
  return { code, stdout, stderr };
}

/** Отказ хука в формате Claude Code: причина или ошибка теста. */
function denyReason(run: HookRun): string {
  assert.equal(run.code, 0, `хук завершился с кодом ${run.code}: ${run.stderr}`);
  const output = JSON.parse(run.stdout) as { hookSpecificOutput?: Record<string, unknown> };
  assert.equal(output.hookSpecificOutput?.hookEventName, "PreToolUse");
  assert.equal(output.hookSpecificOutput?.permissionDecision, "deny");
  const reason = output.hookSpecificOutput?.permissionDecisionReason;
  assert.equal(typeof reason, "string");
  return reason as string;
}

/** «Нет решения»: пустой вывод и код 0 — дальше решает режим CLI. */
function assertDefer(run: HookRun): void {
  assert.equal(run.code, 0, run.stderr);
  assert.equal(run.stdout, "");
}

/** Подставное ядро: отвечает на каждый запрос моста строкой `answer` (или закрывает соединение) и запоминает запросы. */
async function fakeCore(answer: ((request: BridgeRequest) => string) | "close"): Promise<{ path: string; server: Server; requests: BridgeRequest[] }> {
  const requests: BridgeRequest[] = [];
  const path = join(mkdtempSync(join(tmpdir(), "luna-h-")), "core.sock");
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    createInterface({ input: socket }).once("line", (line) => {
      const request = JSON.parse(line) as BridgeRequest;
      requests.push(request);
      if (answer === "close") socket.end();
      else socket.end(`${answer(request)}\n`);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  return { path, server, requests };
}

// --- Мост в режиме hook

test("хук на записанном входе: запрос ядру — kind hook с tool_name, tool_input и tool_use_id; «нет решения» — пустой вывод, код 0", async () => {
  const core = await fakeCore(() => JSON.stringify({ behavior: "defer" }));
  try {
    const [bash, write] = fixtureLines("accept-edits-write.hook.jsonl");
    assertDefer(await runHook(core.path, bash ?? ""));
    assertDefer(await runHook(core.path, write ?? ""));
    const [bashInput, writeInput] = hookInputs("accept-edits-write.hook.jsonl");
    assert.equal(writeInput?.hook_event_name, "PreToolUse");
    assert.deepEqual(core.requests, [
      { run: "run-1", kind: "hook", call: { tool_name: "Bash", input: bashInput?.tool_input, tool_use_id: bashInput?.tool_use_id } },
      { run: "run-1", kind: "hook", call: { tool_name: "Write", input: writeInput?.tool_input, tool_use_id: writeInput?.tool_use_id } },
    ]);
  } finally {
    core.server.close();
  }
});

test("хук: отказ ядра — permissionDecision deny с причиной ядра", async () => {
  const core = await fakeCore(() => JSON.stringify({ behavior: "deny", message: WEB_DENIED_MESSAGE }));
  try {
    assert.equal(denyReason(await runHook(core.path, fixtureLines("web-then-write.hook.jsonl")[0] ?? "")), WEB_DENIED_MESSAGE);
  } finally {
    core.server.close();
  }
});

test("хук при своей беде отказывает: сокета нет, ядро закрыло соединение, ответ непонятен", async () => {
  const input = fixtureLines("web-then-write.hook.jsonl")[0] ?? "";
  assert.match(denyReason(await runHook(join(tmpdir(), "luna-no-such-core.sock"), input)), /^Luna недоступна: /);

  const closing = await fakeCore("close");
  try {
    assert.match(denyReason(await runHook(closing.path, input)), /^Luna недоступна: ядро закрыло соединение/);
  } finally {
    closing.server.close();
  }
  for (const answer of ["не json", "null", JSON.stringify({ behavior: "allow", updatedInput: {} }), JSON.stringify({})]) {
    const core = await fakeCore(() => answer);
    try {
      // Ни «allow», ни пустой объект хук разрешением не считает: всё, кроме defer, — отказ.
      const reason = denyReason(await runHook(core.path, input));
      assert.ok(reason.startsWith("Luna"), `${answer}: ${reason}`);
    } finally {
      core.server.close();
    }
  }
});

test("хук: вход не разобран — код 2 (CLI блокирует вызов), stdout пуст, ядро не спрошено", async () => {
  const core = await fakeCore(() => JSON.stringify({ behavior: "defer" }));
  try {
    for (const input of ["", "не json", "[]"]) {
      const run = await runHook(core.path, input);
      assert.equal(run.code, 2, input);
      assert.equal(run.stdout, "");
      assert.match(run.stderr, /^Luna: вход хука не разобран/);
    }
    assert.equal(core.requests.length, 0);
  } finally {
    core.server.close();
  }
});

test("хук: запуск, которого ядро не знает (закончился), — отказ «задача уже завершена»", async () => {
  const approvals = await openTestApprovals();
  const reason = denyReason(await runHook(approvals.path, fixtureLines("web-then-write.hook.jsonl")[0] ?? "", "no-such-run"));
  assert.equal(reason, "Luna: задача уже завершена");
});

// --- Хук через ядро: подменный CLI запускает команду хука из --settings, как это делает Claude Code

type Step = { print: string[] } | { hook: string };

/**
 * Подменный `claude`: по шагам выводит строки потока и запускает команду хука из `--settings` через
 * `sh -c` со входом хука в stdin; результаты хуков записываются в файл `hooks` (JSON-массив).
 */
function hookingClaude(steps: Step[]): { binary: string; dir: string; hooks: () => HookRun[]; argv: () => string[] } {
  const dir = mkdtempSync(join(tmpdir(), "luna-fake-claude-"));
  const script = join(dir, "claude.mjs");
  writeFileSync(
    script,
    `
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
const argv = process.argv.slice(2);
writeFileSync(${JSON.stringify(join(dir, "argv"))}, argv.join("\\n") + "\\n");
const settings = JSON.parse(argv[argv.indexOf("--settings") + 1]);
const command = settings.hooks.PreToolUse[0].hooks[0].command;
process.stdin.resume();
const results = [];
const hook = (input) => new Promise((resolve) => {
  const child = spawn("/bin/sh", ["-c", command], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8").on("data", (c) => (stdout += c));
  child.stderr.setEncoding("utf8").on("data", (c) => (stderr += c));
  child.on("close", (code) => { results.push({ code, stdout, stderr }); resolve(); });
  child.stdin.end(input);
});
for (const step of ${JSON.stringify(steps)}) {
  if (step.print) for (const line of step.print) process.stdout.write(line + "\\n");
  else await hook(step.hook);
}
writeFileSync(${JSON.stringify(join(dir, "hooks"))}, JSON.stringify(results));
`,
  );
  const binary = join(dir, "claude");
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
  chmodSync(binary, 0o755);
  return {
    binary,
    dir,
    hooks: () => JSON.parse(readFileSync(join(dir, "hooks"), "utf8")) as HookRun[],
    argv: () => readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n"),
  };
}

/** Делит строки потока на шаги: перед каждым вызовом из `hooks` — строки до его `tool_use` включительно. */
function interleave(stream: string[], hooks: string[]): Step[] {
  const steps: Step[] = [];
  let from = 0;
  for (const hook of hooks) {
    const id = (JSON.parse(hook) as HookInput).tool_use_id;
    const at = stream.findIndex((line) => line.includes(`"id":"${id}"`));
    assert.ok(at >= from, `строка с ${id}`);
    steps.push({ print: stream.slice(from, at + 1) }, { hook });
    from = at + 1;
  }
  steps.push({ print: stream.slice(from) });
  return steps;
}

async function runExecutor(executor: ClaudeCodeExecutor, permission: PermissionLevel = "edit_automatically"): Promise<ExecutorEvent[]> {
  const events: ExecutorEvent[] = [];
  for await (const event of executor.run({ prompt: "x", formatRules: "RULES", cwd: tmpdir(), signal: new AbortController().signal, permission })) {
    events.push(event);
    // Хук решает без человека: пауз здесь быть не должно, а пришедшая не повисает.
    if (event.type === "pause") event.respond(false);
  }
  return events;
}

test("чистый запуск на acceptEdits (живой поток sonnet): хук на Bash и Write — «нет решения», файл пишется без паузы", async () => {
  const approvals = await openTestApprovals();
  const claude = hookingClaude(interleave(fixtureLines("accept-edits-write.jsonl"), fixtureLines("accept-edits-write.hook.jsonl")));
  const events = await runExecutor(new ClaudeCodeExecutor({ binary: claude.binary, approvals }));
  assert.equal(events.at(-1)?.type, "done");
  assert.equal(events.some((event) => event.type === "pause" || event.type === "web"), false);
  const hooks = claude.hooks();
  assert.equal(hooks.length, 2);
  for (const run of hooks) assertDefer(run);
  assert.equal(claude.argv()[claude.argv().indexOf("--permission-mode") + 1], "acceptEdits");
});

test("веб, затем запись на acceptEdits (живой поток sonnet): хук отклоняет запись раньше режима, паузы нет", async () => {
  const approvals = await openTestApprovals();
  const claude = hookingClaude(interleave(fixtureLines("web-then-write.accept-edits.jsonl"), fixtureLines("web-then-write.hook.jsonl")));
  const events = await runExecutor(new ClaudeCodeExecutor({ binary: claude.binary, approvals }));
  assert.equal(events.at(-1)?.type, "done");
  assert.equal(events.filter((event) => event.type === "web").length, 1);
  assert.equal(events.some((event) => event.type === "pause"), false);
  const [hook] = claude.hooks();
  assert.ok(hook);
  assert.equal(denyReason(hook), WEB_DENIED_MESSAGE);
});

test("WebFetch и Write в одном сообщении модели: хук на Write — отказ про веб на любом уровне", async () => {
  const [recorded] = hookInputs("web-then-write.hook.jsonl");
  assert.ok(recorded);
  const both = JSON.stringify({
    type: "assistant",
    parent_tool_use_id: null,
    session_id: "s",
    message: {
      content: [
        { type: "tool_use", id: "toolu_fetch", name: "WebFetch", input: { url: "https://example.com", prompt: "x" } },
        { type: "tool_use", id: recorded.tool_use_id, name: "Write", input: recorded.tool_input },
      ],
    },
  });
  const init = fixtureLines("success.jsonl")[0] ?? "";
  const result = JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "готово", session_id: "s" });
  for (const permission of ["manual", "edit_automatically"] as const) {
    const approvals = await openTestApprovals();
    const claude = hookingClaude([{ print: [init, both] }, { hook: JSON.stringify(recorded) }, { print: [result] }]);
    const events = await runExecutor(new ClaudeCodeExecutor({ binary: claude.binary, approvals }), permission);
    assert.equal(events.at(-1)?.type, "done", permission);
    const [hook] = claude.hooks();
    assert.ok(hook);
    assert.equal(denyReason(hook), WEB_DENIED_MESSAGE, permission);
  }
});

test("строка вызова так и не появилась в выводе: хук получает отказ, задача не висит", async () => {
  const approvals = await openTestApprovals();
  const [recorded] = hookInputs("web-then-write.hook.jsonl");
  const claude = hookingClaude([
    { print: [fixtureLines("success.jsonl")[0] ?? ""] },
    { hook: JSON.stringify({ ...recorded, tool_use_id: "toolu_never" }) },
    { print: [JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "готово", session_id: "s" })] },
  ]);
  const events = await runExecutor(new ClaudeCodeExecutor({ binary: claude.binary, approvals, toolUseWaitMs: 100 }));
  assert.equal(events.at(-1)?.type, "done");
  const [hook] = claude.hooks();
  assert.ok(hook);
  assert.match(denyReason(hook), /не сверен с выводом/);
});

test("hookSettings: один хук PreToolUse на запись и команды, команда — node моста в режиме hook с экранированием, срок задан", () => {
  const settings = JSON.parse(hookSettings("/tmp/it's luna.sock", "run-1", "/usr/bin/node")) as {
    hooks: { PreToolUse: { matcher: string; hooks: { type: string; command: string; timeout: number }[] }[] };
  };
  assert.deepEqual(Object.keys(settings.hooks), ["PreToolUse"]);
  const [entry] = settings.hooks.PreToolUse;
  assert.equal(entry?.matcher, "Write|Edit|NotebookEdit|Bash");
  assert.equal(entry?.matcher, HOOK_MATCHER);
  const [hook] = entry?.hooks ?? [];
  assert.equal(hook?.type, "command");
  assert.equal(hook?.timeout, HOOK_TIMEOUT_S);
  assert.equal(hook?.command, `'/usr/bin/node' '${BRIDGE_PATH}' 'hook' '/tmp/it'\\''s luna.sock' 'run-1'`);
});
