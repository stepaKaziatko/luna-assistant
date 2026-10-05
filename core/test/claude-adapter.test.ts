import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { buildArgs, ClaudeCodeExecutor } from "../src/executors/claude-code/adapter.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";

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

async function collect(executor: ClaudeCodeExecutor, signal = new AbortController().signal): Promise<ExecutorEvent[]> {
  const events: ExecutorEvent[] = [];
  for await (const event of executor.run({ prompt: "<task>\nпривет\n</task>", formatRules: "RULES", cwd: tmpdir(), signal })) {
    events.push(event);
  }
  return events;
}

test("запускает CLI в режиме только чтения и передаёт промпт через stdin", async () => {
  const { binary, dir } = fakeClaude(`cat "${fixture("success.jsonl")}"`);
  const events = await collect(new ClaudeCodeExecutor({ binary, model: "sonnet" }));

  assert.equal(events.at(-1)?.type, "done");
  assert.equal(readFileSync(join(dir, "stdin"), "utf8"), "<task>\nпривет\n</task>");
  assert.deepEqual(readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n"), [
    "-p",
    "--output-format", "stream-json",
    "--verbose",
    "--safe-mode",
    "--strict-mcp-config",
    "--tools", "WebFetch,WebSearch,Read,Glob,Grep",
    "--allowedTools", "WebFetch,WebSearch,Read,Glob,Grep",
    "--append-system-prompt", "RULES",
    "--model", "sonnet",
  ]);
});

test("уточнение: прежние флаги и --resume с сессией диалога; без продолжения --resume нет", async () => {
  const plain = buildArgs("RULES", "sonnet");
  const resumed = buildArgs("RULES", "sonnet", { sessionId: "6872ce2a-d1fa-476e-b60c-9c963deff778" });
  assert.deepEqual(resumed, [...plain, "--resume", "6872ce2a-d1fa-476e-b60c-9c963deff778"]);
  assert.equal(plain.includes("--resume"), false);
  for (const flag of ["--safe-mode", "--strict-mcp-config", "--tools", "--allowedTools", "--append-system-prompt", "--model"]) {
    assert.ok(resumed.includes(flag), flag);
  }

  const { binary, dir } = fakeClaude(`cat "${fixture("resume-success.jsonl")}"`);
  const events: ExecutorEvent[] = [];
  for await (const event of new ClaudeCodeExecutor({ binary }).run({
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

test("сессия не найдена: одна ошибка session_not_found, без второй от кода выхода 1", async () => {
  const { binary } = fakeClaude(`cat "${fixture("session-not-found.jsonl")}"; echo "No conversation found" >&2; exit 1`);
  const events = await collect(new ClaudeCodeExecutor({ binary }));
  const failed = events.filter((event) => event.type === "failed");
  assert.equal(failed.length, 1);
  assert.equal(failed[0]?.type === "failed" && failed[0].error.kind, "session_not_found");
});

test("ненулевой код выхода после result не порождает вторую ошибку", async () => {
  const { binary } = fakeClaude(`cat "${fixture("not-logged-in.jsonl")}"; exit 1`);
  const events = await collect(new ClaudeCodeExecutor({ binary }));
  assert.deepEqual(events.filter((event) => event.type === "failed").length, 1);
  assert.deepEqual(events.at(-1), {
    type: "failed",
    error: { kind: "auth", message: "Not logged in · Please run /login" },
  });
});

test("падение CLI без result: ошибка с хвостом stderr", async () => {
  const { binary } = fakeClaude(`echo "boom" >&2; exit 3`);
  const events = await collect(new ClaudeCodeExecutor({ binary }));
  assert.deepEqual(events, [
    { type: "failed", error: { kind: "unknown", message: "Claude Code завершился без результата: boom" } },
  ]);
});

test("бинарник не найден: not_installed", async () => {
  const events = await collect(new ClaudeCodeExecutor({ binary: "/nonexistent/claude" }));
  assert.equal(events.length, 1);
  assert.equal(events[0]?.type === "failed" && events[0].error.kind, "not_installed");
});

test("отмена убивает процесс и не порождает ошибку", async () => {
  const { binary } = fakeClaude(`head -n 1 "${fixture("success.jsonl")}"; exec sleep 30`);
  const abort = new AbortController();
  const events: ExecutorEvent[] = [];
  const started = Date.now();
  for await (const event of new ClaudeCodeExecutor({ binary }).run({
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
