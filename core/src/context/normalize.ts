import type { TaskContext } from "../rpc/protocol.gen.ts";

export const MAX_URL_LENGTH = 2000;
export const MAX_TITLE_LENGTH = 300;
export const MAX_SELECTION_LENGTH = 20_000;

/**
 * Приводит контекст от shell к предсказуемому виду: только известные поля, однострочные
 * app/url/title, ограниченная длина. Возвращает undefined, если после чистки ничего не осталось.
 */
export function normalizeContext(raw: unknown): TaskContext | undefined {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const source = raw as Record<string, unknown>;
  const context: TaskContext = {};

  const app = source.app as Record<string, unknown> | null | undefined;
  if (app && typeof app === "object") {
    const name = singleLine(app.name, MAX_TITLE_LENGTH);
    const bundleId = singleLine(app.bundleId, MAX_TITLE_LENGTH);
    if (name && bundleId) context.app = { bundleId, name };
  }

  const url = singleLine(source.url, MAX_URL_LENGTH);
  if (url) context.url = url;
  const title = singleLine(source.title, MAX_TITLE_LENGTH);
  if (title) context.title = title;

  if (typeof source.selection === "string") {
    const selection = truncate(source.selection.trim(), MAX_SELECTION_LENGTH);
    if (selection) context.selection = selection;
  }

  return Object.keys(context).length > 0 ? context : undefined;
}

function singleLine(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = truncate(value.replace(/\s+/g, " ").trim(), limit);
  return text === "" ? undefined : text;
}

function truncate(text: string, limit: number): string {
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}
