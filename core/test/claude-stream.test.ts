import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { ClaudeStreamParser } from "../src/executors/claude-code/stream.ts";
import type { ExecutorEvent } from "../src/executors/executor.ts";

function parseFixture(name: string): ExecutorEvent[] {
  const parser = new ClaudeStreamParser();
  const text = readFileSync(new URL(`./fixtures/claude-code/${name}`, import.meta.url), "utf8");
  return text.split("\n").flatMap((line) => parser.push(line));
}

test("успешный запуск: сессия, прогресс по инструментам, результат", () => {
  assert.deepEqual(parseFixture("success.jsonl"), [
    { type: "session", sessionId: "6872ce2a-d1fa-476e-b60c-9c963deff778" },
    { type: "model", model: "claude-fable-5" },
    { type: "progress", text: "читает README.md" },
    { type: "progress", text: "пишет ответ…" },
    { type: "done", result: "Проект — крошечный демо-проект для захвата фикстур (fixture capture)." },
  ]);
});

test("CLI не авторизован: ошибка auth с текстом от CLI", () => {
  const events = parseFixture("not-logged-in.jsonl");
  assert.deepEqual(events.at(-1), {
    type: "failed",
    error: { kind: "auth", message: "Not logged in · Please run /login" },
  });
});

test("исчерпан лимит: ошибка rate_limit", () => {
  const events = parseFixture("rate-limit.synthetic.jsonl");
  assert.deepEqual(events.at(-1), {
    type: "failed",
    error: { kind: "rate_limit", message: "You've hit your limit · resets 3pm" },
  });
});

test("сессия для --resume не найдена: session_not_found с человеческим текстом", () => {
  const events = parseFixture("session-not-found.jsonl");
  // Поток без init: модели в нём нет.
  assert.equal(events.length, 2);
  assert.deepEqual(events[0], { type: "session", sessionId: "3f0c9a52-7d1e-4b8a-9c6f-2e5d8a1b4c70" });
  const last = events.at(-1);
  assert.equal(last?.type, "failed");
  if (last?.type !== "failed") return;
  assert.equal(last.error.kind, "session_not_found");
  assert.ok(!last.error.message.includes("error_during_execution"), last.error.message);
});

test("уточнение в продолжённой сессии: сессия и результат", () => {
  const events = parseFixture("resume-success.jsonl");
  assert.equal(events[0]?.type, "session");
  const last = events.at(-1);
  assert.equal(last?.type, "done");
  assert.match(last?.type === "done" ? last.result : "", /417/);
});

test("описания инструментов", () => {
  const describe = (name: string, input: object): ExecutorEvent[] =>
    new ClaudeStreamParser().push(
      JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name, input }] } }),
    );

  // Веб — ещё и событие `web` перед прогрессом.
  assert.deepEqual(describe("WebFetch", { url: "https://www.github.com/owner/repo" }), [
    { type: "web" },
    { type: "progress", text: "открывает github.com" },
  ]);
  assert.deepEqual(describe("WebSearch", { query: "swift nspanel" }), [
    { type: "web" },
    { type: "progress", text: "ищет в вебе: swift nspanel" },
  ]);
  assert.deepEqual(describe("Grep", { pattern: "TODO" }), [{ type: "progress", text: "ищет «TODO»" }]);
  assert.deepEqual(describe("Mystery", {}), [{ type: "progress", text: "использует Mystery" }]);
});

test("мусор и неизвестные события не ломают разбор", () => {
  const parser = new ClaudeStreamParser();
  assert.deepEqual(parser.push("not json"), []);
  assert.deepEqual(parser.push("null"), []);
  assert.deepEqual(parser.push('{"type":"something_new"}'), []);
});

test("завершение с ошибкой без текста результата", () => {
  const events = new ClaudeStreamParser().push('{"type":"result","subtype":"error_max_turns","is_error":true}');
  assert.deepEqual(events, [
    {
      type: "failed",
      error: { kind: "unknown", message: "Claude Code завершился с ошибкой (error_max_turns)" },
    },
  ]);
});

test("веб: событие web одно на поток — от WebFetch или WebSearch, в том числе у субагента; вызовы запоминаются по id", () => {
  const line = (id: string, name: string, parent: string | null = null) =>
    JSON.stringify({ type: "assistant", parent_tool_use_id: parent, message: { content: [{ type: "tool_use", id, name, input: {} }] } });

  const sub = new ClaudeStreamParser();
  assert.deepEqual(sub.push(line("t1", "Read")).filter((event) => event.type === "web"), []);
  assert.equal(sub.webUsed, false);
  // Субагент: прогресса нет, но веб засчитан.
  assert.deepEqual(sub.push(line("t2", "WebSearch", "t-agent")), [{ type: "web" }]);
  assert.equal(sub.webUsed, true);
  assert.deepEqual(sub.push(line("t3", "WebFetch")).filter((event) => event.type === "web"), []);
  assert.ok(sub.hasToolUse("t1") && sub.hasToolUse("t2") && sub.hasToolUse("t3"));
  assert.equal(sub.hasToolUse("t4"), false);
});

test("живой поток web-then-write: событие web приходит на WebSearch, до строки с Write", () => {
  const parser = new ClaudeStreamParser();
  const lines = readFileSync(new URL("./fixtures/claude-code/web-then-write.jsonl", import.meta.url), "utf8").trimEnd().split("\n");
  let webAt = -1;
  let writeAt = -1;
  lines.forEach((text, index) => {
    if (parser.push(text).some((event) => event.type === "web")) webAt = index;
    if (writeAt === -1 && text.includes('"name":"Write"')) writeAt = index;
  });
  assert.ok(webAt >= 0 && writeAt > webAt, `web ${webAt}, write ${writeAt}`);
  assert.ok(parser.webUsed);
});
