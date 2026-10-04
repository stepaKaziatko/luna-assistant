import { basename } from "node:path";
import type { TaskErrorKind } from "../../rpc/protocol.gen.ts";
import type { ExecutorEvent } from "../executor.ts";

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
}

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

function describeTool(name: string, input: Record<string, unknown>): string {
  const text = (key: string): string | undefined => {
    const value = input[key];
    return typeof value === "string" && value !== "" ? value : undefined;
  };

  switch (name) {
    case "Read": {
      const path = text("file_path");
      return path ? `читает ${basename(path)}` : "читает файл";
    }
    case "Glob": {
      const pattern = text("pattern");
      return pattern ? `ищет файлы ${pattern}` : "ищет файлы";
    }
    case "Grep": {
      const pattern = text("pattern");
      return pattern ? `ищет «${pattern}»` : "ищет в файлах";
    }
    case "WebFetch": {
      const url = text("url");
      return url ? `открывает ${hostOf(url)}` : "открывает страницу";
    }
    case "WebSearch": {
      const query = text("query");
      return query ? `ищет в вебе: ${query}` : "ищет в вебе";
    }
    default:
      return `использует ${name}`;
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}
