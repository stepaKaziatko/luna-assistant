import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { ExecutorStatus } from "../../rpc/protocol.gen.ts";
import type { Executor, ExecutorEvent, ExecutorRequest } from "../executor.ts";
import { resolveBinary } from "../resolve-binary.ts";
import { COMMAND_TOO_LONG, decide, describeApproval, tooLongToShow, WEB_DENIED, type Decision, type ToolCall } from "./approval.ts";
import type { ApprovalSocket } from "./socket.ts";
import { ClaudeStreamParser } from "./stream.ts";

// Чтение разрешено без вопроса. Запись файлов и команды (`Bash`) доступны, но не разрешены заранее:
// всё, что CLI не пропускает сам, идёт через мост (`--permission-prompt-tool`) и ждёт ответа человека
// в Luna. Какие команды спрашивать, решает CLI в своём режиме (`ls` в рабочем каталоге он не спрашивает),
// Luna списков команд не ведёт. Запуск только на чтение (`readOnly`) получает перечень чтения целиком и
// ничего сверх него: новые инструменты попадают в него, только если их сюда допишут.
export const READ_ONLY_TOOLS = "WebFetch,WebSearch,Read,Glob,Grep";
const WRITE_TOOLS = "Write,Edit,NotebookEdit";
const SHELL_TOOLS = "Bash";
export const AVAILABLE_TOOLS = `${READ_ONLY_TOOLS},${WRITE_TOOLS},${SHELL_TOOLS}`;
export const ALLOWED_TOOLS = READ_ONLY_TOOLS;

/** Имя MCP-сервера моста и его инструмента: так CLI называет permission prompt. */
export const MCP_SERVER = "luna";
export const PERMISSION_TOOL = `mcp__${MCP_SERVER}__approve`;

/**
 * Сколько мост ждёт, пока в разобранном выводе CLI появится вызов, о котором он спрашивает. CLI
 * пишет строку с `tool_use` раньше, чем зовёт мост, — ожидание покрывает лишь разницу в доставке
 * двух потоков. Не дождались — отказ: без строки неизвестно, ходил ли исполнитель в веб.
 */
export const TOOL_USE_WAIT_MS = 5000;

/** Отказ на вызов, который пришёл или остался без ответа к концу запуска. */
const FINISHED: Decision = { behavior: "deny", message: "Luna: задача завершена" };

/** Отказ, когда строки с вызовом в выводе CLI так и не появилось. */
const UNMATCHED: Decision = { behavior: "deny", message: "Luna: запрос не сверен с выводом исполнителя, действие не выполнено" };

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
  /** Запасное значение для --model, когда в запросе модели нет; иначе — модель из настроек CLI. */
  model?: string;
  /** Канал подтверждений от моста к ядру; без него исполнитель запускать нельзя (кроме запуска на чтение). */
  approvals?: ApprovalSocket;
  /** Сколько вызов моста ждёт своей строки в выводе CLI; по умолчанию `TOOL_USE_WAIT_MS`. */
  toolUseWaitMs?: number;
}

export type ClaudeArgs = {
  formatRules: string;
  model?: string;
  resume?: { sessionId: string };
} & (
  /** Содержимое `--mcp-config`: только наш мост, см. `bridgeConfig`. */
  | { readOnly?: false; mcpConfig: string }
  /** Только чтение: ни инструментов записи, ни моста — спрашивать человека не о чем. */
  | { readOnly: true }
);

/** Файл моста рядом с адаптером: `bridge.ts` в исходниках, `bridge.js` в сборке. */
export const BRIDGE_PATH = fileURLToPath(new URL(import.meta.url.replace(/adapter\.(ts|js)$/, "bridge.$1")));

/** `--mcp-config` с одним сервером — нашим мостом, запущенным тем же Node, что и ядро. */
export function bridgeConfig(socketPath: string, runId: string, node = process.execPath): string {
  return JSON.stringify({
    mcpServers: { [MCP_SERVER]: { type: "stdio", command: node, args: [BRIDGE_PATH, socketPath, runId] } },
  });
}

/**
 * Аргументы `claude -p`; с `resume` — те же флаги плюс `--resume <sessionId>`. `readOnly` проверяется
 * первым и перебивает всё остальное: перечень инструментов — только чтение, моста нет.
 */
export function buildArgs(options: ClaudeArgs): string[] {
  const access = options.readOnly
    ? ["--permission-mode", "default", "--tools", READ_ONLY_TOOLS]
    : [
        "--mcp-config", options.mcpConfig,
        "--permission-prompt-tool", PERMISSION_TOOL,
        // Уровень `manual`: всё, что CLI не разрешил сам, идёт человеку через мост.
        "--permission-mode", "default",
        "--tools", AVAILABLE_TOOLS,
      ];
  const args = [
    "-p",
    "--output-format", "stream-json",
    "--verbose",
    // Без пользовательских настроек, CLAUDE.md, навыков, плагинов и команд: быстрее старт, меньше расход
    // лимита и предсказуемый набор инструментов. `--safe-mode` для этого не годится: он отключает и MCP,
    // а через MCP идёт мост подтверждений.
    "--setting-sources", "",
    "--disable-slash-commands",
    "--strict-mcp-config",
    ...access,
    "--allowedTools", ALLOWED_TOOLS,
    "--append-system-prompt", options.formatRules,
  ];
  if (options.model) args.push("--model", options.model);
  // Сессии Claude Code привязаны к рабочей директории: уточнение запускается там же, где задача.
  if (options.resume) args.push("--resume", options.resume.sessionId);
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
    // Запуску на чтение канал не нужен: спрашивать человека не о чем.
    const approvals = this.options.approvals;
    if (!approvals && !request.readOnly) {
      yield {
        type: "failed",
        error: { kind: "unknown", message: "Канал подтверждений не открыт: исполнитель не может спрашивать разрешения. Проверьте каталог данных Luna." },
      };
      return;
    }
    if (request.signal.aborted) return;

    const env = { ...process.env };
    for (const name of PARENT_SESSION_ENV) delete env[name];

    const runId = randomUUID();
    const args = buildArgs({
      formatRules: request.formatRules,
      ...(request.readOnly || !approvals ? { readOnly: true as const } : { mcpConfig: bridgeConfig(approvals.path, runId) }),
      ...(request.model ?? this.options.model ? { model: request.model ?? this.options.model } : {}),
      ...(request.resume ? { resume: request.resume } : {}),
    });
    const child = spawn(binary, args, { cwd: request.cwd, env, stdio: ["pipe", "pipe", "pipe"] });
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

    // События двух источников — вывода CLI и вызовов моста — идут потребителю одной очередью.
    const queue = new EventQueue();
    const parser = new ClaudeStreamParser();
    const stdout = new StreamProgress(parser, this.options.toolUseWaitMs ?? TOOL_USE_WAIT_MS);
    // Ответы, которых мост ещё ждёт: по окончании запуска они закрываются отказом, чтобы ничего не висело.
    const waiting = new Set<(decision: Decision) => void>();
    let over = false;
    const ask = (call: ToolCall) => new Promise<Decision>((resolve) => {
      // Пока вызов ждал вывода, запуск мог закончиться: спрашивать уже некого.
      if (over) return resolve(FINISHED);
      waiting.add(resolve);
      queue.push({
        type: "pause",
        kind: "approval",
        request: describeApproval(call, request.cwd),
        respond: (allow) => {
          waiting.delete(resolve);
          resolve(decide(call, allow));
        },
      });
    });
    const unregister = request.readOnly || !approvals
      ? () => {}
      : approvals.register(runId, async (call) => {
          // Мост и stdout — разные потоки: решение принимается, когда разобран весь вывод до этого вызова.
          if (!(await stdout.reached(call.tool_use_id))) return UNMATCHED;
          // После веба запись и команды запрещены: человеку такой запрос не показывается.
          if (parser.webUsed) return WEB_DENIED;
          // Команду, которую человек не прочтёт целиком, не показываем: граница показа, а не политика.
          if (tooLongToShow(call)) return COMMAND_TOO_LONG;
          return ask(call);
        });

    void (async () => {
      let finished = false;
      for await (const line of createInterface({ input: child.stdout, crlfDelay: Infinity })) {
        for (const event of parser.push(line)) {
          if (event.type === "done" || event.type === "failed") finished = true;
          queue.push(event);
        }
        stdout.advance();
      }
      stdout.end();
      const { code, error } = await exit;
      if (!finished && !request.signal.aborted) {
        const detail = error?.message ?? (stderr.trim() || `код выхода ${code}`);
        queue.push({ type: "failed", error: { kind: "unknown", message: `Claude Code завершился без результата: ${detail}` } });
      }
      queue.close();
    })();

    try {
      for await (const event of queue) yield event;
    } finally {
      over = true;
      unregister();
      for (const resolve of waiting) resolve(FINISHED);
      waiting.clear();
      request.signal.removeEventListener("abort", kill);
      if (child.exitCode === null && child.signalCode === null) kill();
    }
  }
}

/** Докуда разобран вывод CLI: вызов моста ждёт строки со своим `tool_use_id`. */
class StreamProgress {
  private readonly parser: ClaudeStreamParser;
  private readonly waiters = new Set<() => void>();
  private readonly waitMs: number;
  private ended = false;

  constructor(parser: ClaudeStreamParser, waitMs: number) {
    this.parser = parser;
    this.waitMs = waitMs;
  }

  /**
   * True — строка с вызовом `id` разобрана (или вывод кончился: больше ждать нечего). False — не
   * дождались за `waitMs`. Без `id` сверять не с чем — решение по тому, что уже разобрано.
   */
  reached(id: string | undefined): Promise<boolean> {
    const done = () => id === undefined || this.ended || this.parser.hasToolUse(id);
    if (done()) return Promise.resolve(true);
    return new Promise((resolve) => {
      const check = () => {
        if (!done()) return;
        this.waiters.delete(check);
        clearTimeout(timer);
        resolve(true);
      };
      const timer = setTimeout(() => {
        this.waiters.delete(check);
        resolve(false);
      }, this.waitMs);
      this.waiters.add(check);
    });
  }

  /** Разобрана очередная строка. */
  advance(): void {
    for (const check of [...this.waiters]) check();
  }

  /** Вывод кончился. */
  end(): void {
    this.ended = true;
    this.advance();
  }
}

/** Очередь событий для асинхронного перебора: производители кладут, потребитель ждёт. */
class EventQueue implements AsyncIterable<ExecutorEvent> {
  private readonly items: ExecutorEvent[] = [];
  private closed = false;
  private wake: (() => void) | undefined;

  push(event: ExecutorEvent): void {
    if (this.closed) return;
    this.items.push(event);
    this.wake?.();
  }

  close(): void {
    this.closed = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<ExecutorEvent> {
    for (;;) {
      const event = this.items.shift();
      if (event) {
        yield event;
        continue;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => (this.wake = resolve));
      this.wake = undefined;
    }
  }
}
