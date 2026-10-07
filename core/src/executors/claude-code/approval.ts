import { isAbsolute, resolve } from "node:path";
import type { PauseRequest } from "../executor.ts";

// Как показать человеку вызов инструмента Claude Code, который ждёт разрешения. Всё — чистый
// текст для карточки: оболочка не разбирает его ни как Markdown, ни как ссылки.

/** Сколько знаков фрагмента показывается; остальное отмечается пометкой об обрезке. */
export const DETAIL_LIMIT = 2000;

/** Вызов инструмента так, как его присылает CLI в permission prompt. */
export interface ToolCall {
  tool_name: string;
  input: Record<string, unknown>;
  tool_use_id?: string;
}

/** Ответ CLI на permission prompt (Claude Code 2.1.181): текст JSON в содержимом инструмента. */
export type Decision =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

/** Пояснение, которое получает исполнитель, когда человек отклонил действие в карточке. */
export const DENIED_MESSAGE = "Пользователь отклонил действие в Luna";

/** Описание запроса для карточки; относительный путь приводится к абсолютному от `cwd`. */
export function describeApproval(call: ToolCall, cwd: string): PauseRequest {
  const { tool_name: tool, input } = call;
  const text = (key: string): string | undefined => {
    const value = input[key];
    return typeof value === "string" ? value : undefined;
  };
  const path = (key: string): string | undefined => {
    const value = text(key);
    if (value === undefined || value === "") return undefined;
    return isAbsolute(value) ? value : resolve(cwd, value);
  };

  switch (tool) {
    case "Write": {
      const content = text("content") ?? "";
      const size = `${content.length} ${plural(content.length, "знак", "знака", "знаков")}`;
      return withTarget({ tool, kind: "write", summary: "Записать файл", detail: `${clip(content)}\n\nРазмер: ${size}` }, path("file_path"));
    }
    case "Edit":
      return withTarget(
        { tool, kind: "edit", summary: "Изменить файл", detail: `Заменить:\n${clip(text("old_string") ?? "")}\n\nНа:\n${clip(text("new_string") ?? "")}` },
        path("file_path"),
      );
    case "NotebookEdit":
      return withTarget(
        { tool, kind: "edit", summary: "Изменить блокнот", detail: clip(text("new_source") ?? "") },
        path("notebook_path"),
      );
    default:
      return { tool, kind: "other", summary: `Использовать инструмент ${tool}`, detail: clip(compactJson(input)) };
  }
}

/** Решение человека в терминах CLI: разрешение возвращает вход без изменений. */
export function decide(call: ToolCall, allow: boolean): Decision {
  return allow ? { behavior: "allow", updatedInput: call.input } : { behavior: "deny", message: DENIED_MESSAGE };
}

function withTarget(request: PauseRequest, target: string | undefined): PauseRequest {
  return target ? { ...request, target } : request;
}

/** Начало текста не длиннее `DETAIL_LIMIT` знаков с пометкой, сколько было всего. */
export function clip(value: string, limit = DETAIL_LIMIT): string {
  const chars = [...value];
  if (chars.length <= limit) return value;
  return `${chars.slice(0, limit).join("")}… (обрезано, всего ${chars.length} ${plural(chars.length, "знак", "знака", "знаков")})`;
}

function compactJson(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return String(value);
  }
}

function plural(count: number, one: string, few: string, many: string): string {
  const tens = count % 100;
  if (tens >= 11 && tens <= 19) return many;
  switch (count % 10) {
    case 1: return one;
    case 2: case 3: case 4: return few;
    default: return many;
  }
}
