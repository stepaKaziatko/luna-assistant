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

/**
 * Ответ хуку `PreToolUse`: отказ с причиной либо «нет решения» (`defer`) — вызов идёт дальше по
 * режиму CLI и, если тот спросит, через permission prompt. Разрешения хук не даёт никогда.
 */
export type HookDecision =
  | { behavior: "deny"; message: string }
  | { behavior: "defer" };

/** «Нет решения»: хук не вмешивается. */
export const HOOK_DEFER: HookDecision = { behavior: "defer" };

/** Пояснение исполнителю, почему запрос отклонён без человека: в задаче уже было содержимое из сети. */
export const WEB_DENIED_MESSAGE = "Luna: после обращения к вебу запись и команды в этой задаче запрещены";

/** Отказ, который мост получает после похода исполнителя в веб; человек запроса не видит. */
export const WEB_DENIED = { behavior: "deny", message: WEB_DENIED_MESSAGE } as const satisfies Decision & HookDecision;

/**
 * Самая длинная команда, которую человек проверяет в подтверждении, в символах Unicode. Это граница
 * показа, а не политика: команду длиннее человек целиком не прочтёт, поэтому она отклоняется без показа.
 */
export const COMMAND_LIMIT = 20_000;

/** Пояснение исполнителю, почему команда отклонена без человека. */
export const COMMAND_TOO_LONG_MESSAGE = "Luna: команда длиннее 20 000 знаков, проверить её в подтверждении нельзя; действие не выполнено";

/** Отказ мосту на команду длиннее `COMMAND_LIMIT`; человек запроса не видит. */
export const COMMAND_TOO_LONG: Decision = { behavior: "deny", message: COMMAND_TOO_LONG_MESSAGE };

/** Вызов — команда, которую нельзя показать человеку целиком: длиннее `COMMAND_LIMIT` символов. */
export function tooLongToShow(call: ToolCall): boolean {
  const command = call.input.command;
  return call.tool_name === "Bash" && typeof command === "string" && [...command].length > COMMAND_LIMIT;
}

/**
 * Ответ мосту хука `PermissionRequest` чужой сессии (режим `agent-hook`): `allow` и `deny` — решение
 * человека в Luna, `none` — «нет решения», диалог остаётся в терминале сессии. Хук не обязан ждать
 * ядро: нет сокета, нет запроса, сессия неизвестна — тоже `none`.
 */
export type AgentHookAnswer =
  | { behavior: "allow" }
  | { behavior: "deny"; message: string }
  | { behavior: "none" };

/** Пояснение агенту чужой сессии, когда человек отклонил действие в Luna. */
export const AGENT_DENIED_MESSAGE = "Отклонено в Luna";

/** «Нет решения»: хук ничего не печатает, и CLI решает сам (диалог в терминале). */
export const AGENT_HOOK_NONE: AgentHookAnswer = { behavior: "none" };

/**
 * Чьё действие описывается: задача Luna (`task`) или чужая сессия агента (`session`). От этого зависит
 * подпись каталога в подробностях команды.
 */
export type ApprovalSubject = "task" | "session";

/** Описание запроса для карточки; относительный путь приводится к абсолютному от `cwd`. */
export function describeApproval(call: ToolCall, cwd: string, subject: ApprovalSubject = "task"): PauseRequest {
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
    case "Bash": {
      const command = text("command");
      return command ? describeCommand(tool, command, cwd, text("description"), subject) : other(tool, input);
    }
    default:
      return other(tool, input);
  }
}

/**
 * Команда показывается целиком и как есть: человек разрешает именно её, а не подпись агента. Подпись —
 * отдельной строкой и в одну строку, чтобы текст агента не нарисовал в блоке поддельные «Размер…» или
 * «Каталог…». Каталог — тот, где запущен исполнитель: CLI в запросе каталог не присылает, а сессия может
 * помнить `cd` прошлой команды, поэтому подпись — «Каталог задачи», а не «выполнится в». У чужой сессии
 * каталог приходит в самом запросе хука, подпись — «Каталог сессии».
 */
function describeCommand(tool: string, command: string, cwd: string, description: string | undefined, subject: ApprovalSubject): PauseRequest {
  const lines = command.split("\n").length;
  const chars = [...command].length;
  const detail = [
    `Размер: ${lines} ${plural(lines, "строка", "строки", "строк")}, ${chars} ${plural(chars, "знак", "знака", "знаков")}`,
    `${subject === "session" ? "Каталог сессии" : "Каталог задачи"}: ${cwd}`,
  ];
  const signature = description === undefined ? "" : oneLine(description);
  if (signature) detail.push(`Подпись агента: ${clip(signature)}`);
  return { tool, kind: "shell", summary: "Выполнить команду", target: command, detail: detail.join("\n") };
}

/** Незнакомый вызов: имя инструмента и его вход как JSON. */
function other(tool: string, input: Record<string, unknown>): PauseRequest {
  return { tool, kind: "other", summary: `Использовать инструмент ${tool}`, detail: clip(compactJson(input)) };
}

/** Текст в одну строку: любые переводы строк — пробел, края без пробелов. */
function oneLine(value: string): string {
  return value.replace(/\s*[\r\n\v\f\u0085\u2028\u2029]+\s*/g, " ").trim();
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
