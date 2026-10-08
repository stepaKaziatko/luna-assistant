import { basename } from "node:path";

// Человекочитаемое описание вызова инструмента Claude Code: для прогресса задач Luna
// и для ленты сессий, за которыми Luna только наблюдает.

const COMMAND_LIMIT = 60;

/** Вызов инструмента для ленты: род инструмента, над чем он работает и строка целиком. */
export interface ToolStep {
  /** Род инструмента — значение `AgentStep.tool`. */
  tool: string;
  /** Над чем работает инструмент, коротко. */
  target?: string;
  text: string;
}

export function describeTool(name: string, input: Record<string, unknown>): string {
  return toolStep(name, input).text;
}

export function toolStep(name: string, input: Record<string, unknown>): ToolStep {
  const text = (key: string): string | undefined => {
    const value = input[key];
    return typeof value === "string" && value !== "" ? value : undefined;
  };
  /** С целью — «глагол цель», без неё — запасная строка. */
  const step = (tool: string, target: string | undefined, withTarget: (target: string) => string, bare: string): ToolStep =>
    target ? { tool, target, text: withTarget(target) } : { tool, text: bare };

  switch (name) {
    case "Read": {
      const path = text("file_path");
      return step("read", path && basename(path), (file) => `читает ${file}`, "читает файл");
    }
    case "Edit":
    case "MultiEdit":
    case "NotebookEdit": {
      const path = text("file_path") ?? text("notebook_path");
      return step("edit", path && basename(path), (file) => `правит ${file}`, "правит файл");
    }
    case "Write": {
      const path = text("file_path");
      return step("write", path && basename(path), (file) => `пишет ${file}`, "пишет файл");
    }
    case "Bash": {
      // Агент сам подписывает команду — для строки прогресса подпись понятнее её текста. Подтверждение
      // подписи не доверяет и показывает команду целиком (`approval.ts`).
      const command = text("description") ?? text("command");
      return step("shell", command && oneLine(command, COMMAND_LIMIT), (line) => `выполняет: ${line}`, "выполняет команду");
    }
    case "Glob":
      return step("search", text("pattern"), (pattern) => `ищет файлы ${pattern}`, "ищет файлы");
    case "Grep":
      return step("search", text("pattern"), (pattern) => `ищет «${pattern}»`, "ищет в файлах");
    case "WebFetch": {
      const url = text("url");
      return step("web", url && hostOf(url), (host) => `открывает ${host}`, "открывает страницу");
    }
    case "WebSearch":
      return step("web", text("query"), (query) => `ищет в вебе: ${query}`, "ищет в вебе");
    case "Agent":
    case "Task": {
      const description = text("description");
      return step(
        "agent", description && oneLine(description, COMMAND_LIMIT),
        (line) => `запускает субагента: ${line}`, "запускает субагента",
      );
    }
    case "TodoWrite":
      return { tool: "plan", text: "обновляет план" };
    case "AskUserQuestion":
      return { tool: "ask", text: "задаёт вопрос" };
    case "Skill":
      return step("skill", text("skill"), (skill) => `применяет навык ${skill}`, "применяет навык");
    default: {
      // mcp__сервер__инструмент
      const mcp = /^mcp__(.+?)__(.+)$/.exec(name);
      return mcp
        ? { tool: "mcp", target: `${mcp[1]} · ${mcp[2]}`, text: `использует ${mcp[1]} · ${mcp[2]}` }
        : { tool: "other", target: name, text: `использует ${name}` };
    }
  }
}

/** Первая строка текста без лишних пробелов, не длиннее limit. */
export function oneLine(value: string, limit: number): string {
  const line = value.trim().split("\n", 1)[0]?.replace(/\s+/g, " ") ?? "";
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line;
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}
