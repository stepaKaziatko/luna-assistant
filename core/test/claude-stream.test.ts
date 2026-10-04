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

test("описания инструментов", () => {
  const describe = (name: string, input: object): ExecutorEvent[] =>
    new ClaudeStreamParser().push(
      JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name, input }] } }),
    );

  assert.deepEqual(describe("WebFetch", { url: "https://www.github.com/owner/repo" }), [
    { type: "progress", text: "открывает github.com" },
  ]);
  assert.deepEqual(describe("WebSearch", { query: "swift nspanel" }), [
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
