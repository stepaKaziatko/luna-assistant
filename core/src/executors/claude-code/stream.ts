import type { TaskErrorKind } from "../../rpc/protocol.gen.ts";
import type { ExecutorEvent } from "../executor.ts";
import { describeTool } from "./tools.ts";

// Разбор `claude -p --output-format stream-json --verbose`.
// Формат сверен с Claude Code 2.1.181; фикстуры — в core/test/fixtures/claude-code.

interface ContentBlock {
  type?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
}

interface StreamLine {
  type?: string;
  subtype?: string;
  session_id?: string;
  /** У `system`/`init` — модель сессии. */
  model?: unknown;
  parent_tool_use_id?: string | null;
  error?: string;
  message?: { content?: ContentBlock[] };
  rate_limit_info?: { status?: string };
  is_error?: boolean;
  api_error_status?: number | null;
  result?: string;
  /** У `result` с ошибкой выполнения — тексты ошибок CLI. */
  errors?: unknown[];
}

/** Так CLI сообщает, что сессии для `--resume` нет (Claude Code 2.1.181). */
const SESSION_NOT_FOUND = "No conversation found with session ID";

/** Инструменты Claude Code, которые приносят содержимое из сети: после них задача недоверенная. */
export const WEB_TOOLS: ReadonlySet<string> = new Set(["WebFetch", "WebSearch"]);

export class ClaudeStreamParser {
  private errorKind: TaskErrorKind | undefined;
  private sessionId: string | undefined;
  /** Вызовы инструментов (`tool_use.id`), уже прошедшие через разбор, — в том числе у субагентов. */
  private readonly toolUses = new Set<string>();
  /** В потоке был вызов `WebFetch`/`WebSearch` — неважно, успешный ли. */
  private web = false;

  /** Был ли в разобранном выводе поход в веб. */
  get webUsed(): boolean {
    return this.web;
  }

  /** Разобрана ли уже строка с вызовом инструмента `id`. */
  hasToolUse(id: string): boolean {
    return this.toolUses.has(id);
  }

  /** Принимает одну строку stdout и возвращает события, которые из неё следуют. */
  push(line: string): ExecutorEvent[] {
    if (line.trim() === "") return [];
    let data: StreamLine;
    try {
      data = JSON.parse(line) as StreamLine;
    } catch {
      return [];
    }
    if (data === null || typeof data !== "object") return [];

    const events: ExecutorEvent[] = [];
    if (typeof data.session_id === "string" && data.session_id !== this.sessionId) {
      this.sessionId = data.session_id;
      events.push({ type: "session", sessionId: data.session_id });
    }
    // Модель берётся только из init: в assistant-сообщениях она бывает служебной.
    if (data.type === "system" && data.subtype === "init" && isRealModel(data.model)) {
      events.push({ type: "model", model: data.model });
    }

    switch (data.type) {
      case "assistant":
        if (data.error) this.errorKind = kindFromAssistantError(data.error);
        // Веб считается и у субагентов: прочитанное ими возвращается в основную сессию.
        for (const block of data.message?.content ?? []) {
          if (block.type !== "tool_use") continue;
          if (typeof block.id === "string") this.toolUses.add(block.id);
          if (!this.web && block.name !== undefined && WEB_TOOLS.has(block.name)) {
            this.web = true;
            events.push({ type: "web" });
          }
        }
        // События субагентов не показываем: статус ведёт основная сессия.
        if (data.parent_tool_use_id) break;
        for (const block of data.message?.content ?? []) {
          if (block.type === "tool_use" && block.name) {
            events.push({ type: "progress", text: describeTool(block.name, block.input ?? {}) });
          } else if (block.type === "text") {
            events.push({ type: "progress", text: "пишет ответ…" });
          }
        }
        break;
      case "rate_limit_event":
        if (data.rate_limit_info?.status === "rejected") this.errorKind = "rate_limit";
        break;
      case "result":
        events.push(this.finish(data));
        break;
    }
    return events;
  }

  private finish(data: StreamLine): ExecutorEvent {
    if (data.subtype === "success" && !data.is_error) {
      return { type: "done", result: data.result ?? "" };
    }
    if (data.errors?.some((error) => typeof error === "string" && error.startsWith(SESSION_NOT_FOUND))) {
      return {
        type: "failed",
        error: { kind: "session_not_found", message: "Claude Code не нашёл прежний разговор этого диалога" },
      };
    }
    const message = data.result?.trim() || `Claude Code завершился с ошибкой (${data.subtype ?? "unknown"})`;
    const kind = this.errorKind ?? kindFromStatus(data.api_error_status) ?? "unknown";
    return { type: "failed", error: { kind, message } };
  }
}

/** Пустое имя и `<synthetic>` (так CLI подписывает собственные сообщения) моделью не считаются. */
function isRealModel(model: unknown): model is string {
  return typeof model === "string" && model.trim() !== "" && model !== "<synthetic>";
}

function kindFromAssistantError(error: string): TaskErrorKind {
  if (error === "authentication_failed") return "auth";
  if (error === "rate_limit") return "rate_limit";
  return "unknown";
}

function kindFromStatus(status: number | null | undefined): TaskErrorKind | undefined {
  if (status === 401 || status === 403) return "auth";
  if (status === 429) return "rate_limit";
  return undefined;
}
