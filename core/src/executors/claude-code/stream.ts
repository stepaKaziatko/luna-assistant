import type { TaskErrorKind } from "../../rpc/protocol.gen.ts";
import type { ExecutorEvent } from "../executor.ts";
import { describeTool } from "./tools.ts";

// Разбор `claude -p --output-format stream-json --verbose`.
// Формат сверен с Claude Code 2.1.181; фикстуры — в core/test/fixtures/claude-code.

interface ContentBlock {
  type?: string;
  name?: string;
  input?: Record<string, unknown>;
}

interface StreamLine {
  type?: string;
  subtype?: string;
  session_id?: string;
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

export class ClaudeStreamParser {
  private errorKind: TaskErrorKind | undefined;
  private sessionId: string | undefined;

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

    switch (data.type) {
      case "assistant":
        if (data.error) this.errorKind = kindFromAssistantError(data.error);
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
