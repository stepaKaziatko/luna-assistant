import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { ExecutorStatus } from "../../rpc/protocol.gen.ts";
import type { Executor, ExecutorEvent, ExecutorRequest } from "../executor.ts";
import { resolveBinary } from "../resolve-binary.ts";
import { ClaudeStreamParser } from "./stream.ts";

// Только чтение: запись файлов и shell появятся вместе с approval prompt.
const READ_ONLY_TOOLS = "WebFetch,WebSearch,Read,Glob,Grep";

// Маркеры родительской сессии Claude Code. Если ядро запущено из неё (разработка),
// дочерний `claude -p` не должен считать себя её частью.
const PARENT_SESSION_ENV = [
  "CLAUDECODE",
  "CLAUDE_PID",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_SESSION_ID",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_EXECPATH",
  "CLAUDE_CODE_MESSAGING_SOCKET",
  "CLAUDE_CODE_MESSAGING_TOKEN",
];

export interface ClaudeCodeOptions {
  /** Путь к бинарнику; по умолчанию ищется `claude` в PATH и типичных местах установки. */
  binary?: string;
  /** Значение для --model; по умолчанию — модель из настроек CLI. */
  model?: string;
}

/** Аргументы `claude -p`; с `resume` — те же флаги плюс `--resume <sessionId>`. */
export function buildArgs(formatRules: string, model?: string, resume?: { sessionId: string }): string[] {
  const args = [
    "-p",
    "--output-format", "stream-json",
    "--verbose",
    // Без пользовательских MCP, плагинов, хуков и CLAUDE.md: быстрее старт,
    // меньше расход лимита и предсказуемый набор инструментов.
    "--safe-mode",
    "--strict-mcp-config",
    "--tools", READ_ONLY_TOOLS,
    "--allowedTools", READ_ONLY_TOOLS,
    "--append-system-prompt", formatRules,
  ];
  if (model) args.push("--model", model);
  // Сессии Claude Code привязаны к рабочей директории: уточнение запускается там же, где задача.
  if (resume) args.push("--resume", resume.sessionId);
  return args;
}

export class ClaudeCodeExecutor implements Executor {
  readonly id = "claude-code";
  private readonly options: ClaudeCodeOptions;

  constructor(options: ClaudeCodeOptions = {}) {
    this.options = options;
  }

  async status(): Promise<ExecutorStatus> {
    const path = await resolveBinary("claude", this.options.binary);
    return path ? { id: this.id, available: true, path } : { id: this.id, available: false };
  }

  async *run(request: ExecutorRequest): AsyncGenerator<ExecutorEvent> {
    const binary = await resolveBinary("claude", this.options.binary);
    if (!binary) {
      yield {
        type: "failed",
        error: { kind: "not_installed", message: "Claude Code не найден. Установите CLI и выполните `claude` → /login." },
      };
      return;
    }
    if (request.signal.aborted) return;

    const env = { ...process.env };
    for (const name of PARENT_SESSION_ENV) delete env[name];

    const child = spawn(binary, buildArgs(request.formatRules, this.options.model, request.resume), {
      cwd: request.cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const exit = new Promise<{ code: number | null; error?: Error }>((resolve) => {
      child.once("error", (error) => resolve({ code: null, error }));
      child.once("close", (code) => resolve({ code }));
    });
    const kill = () => child.kill("SIGTERM");
    request.signal.addEventListener("abort", kill, { once: true });

    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr = (stderr + chunk).slice(-2000);
    });

    // Промпт идёт через stdin: в argv его мог бы поглотить вариативный флаг (--tools <tools...>).
    child.stdin.on("error", () => {});
    child.stdin.end(request.prompt);

    const parser = new ClaudeStreamParser();
    let finished = false;
    try {
      for await (const line of createInterface({ input: child.stdout, crlfDelay: Infinity })) {
        for (const event of parser.push(line)) {
          if (event.type === "done" || event.type === "failed") finished = true;
          yield event;
        }
      }
      const { code, error } = await exit;
      if (!finished && !request.signal.aborted) {
        const detail = error?.message ?? (stderr.trim() || `код выхода ${code}`);
        yield { type: "failed", error: { kind: "unknown", message: `Claude Code завершился без результата: ${detail}` } };
      }
    } finally {
      request.signal.removeEventListener("abort", kill);
      if (child.exitCode === null && child.signalCode === null) kill();
    }
  }
}
