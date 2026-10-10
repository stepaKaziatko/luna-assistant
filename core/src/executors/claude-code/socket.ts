import { randomBytes } from "node:crypto";
import { chmodSync, readdirSync, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { AgentHookAnswer, Decision, HookDecision, ToolCall } from "./approval.ts";

// Канал от моста (bridge.ts) к ядру: unix-сокет в каталоге данных, один на запуск ядра.
// Мост подключается на каждый вызов, шлёт одну строку JSON `{ run, call, kind? }` и ждёт одну
// строку с решением: на permission prompt — `Decision`, на хук `PreToolUse` (`kind: "hook"`) —
// `HookDecision`. Третий вид — `agent-hook`: хук `PermissionRequest` чужой сессии агента, который поставил
// пользователь; запрос несёт `session`, а не `run`, и ждёт человека в Luna без срока (ограничивает его
// `timeout` самого хука). TCP-порта нет: сокет доступен только владельцу (0600).

/** Имя файла сокета: случайное на каждый запуск; остатки прежних запусков чистятся при старте. */
const SOCKET_NAME = /^approvals-[0-9a-f]+\.sock$/;

/**
 * Вид запроса: `approve` — permission prompt, решение может спросить человека; `hook` — хук
 * `PreToolUse`, решение без человека. Без поля — `approve` (так шлёт MCP-режим моста).
 */
export type BridgeRequestKind = "approve" | "hook";

/** Что присылает мост запуска исполнителя. */
export interface BridgeRequest {
  /** Запуск исполнителя, которому адресован вызов: мосту его передают аргументом. */
  run: string;
  call: ToolCall;
  kind?: BridgeRequestKind;
}

/** Что присылает мост хука `PermissionRequest` чужой сессии: сессия, каталог, вызов инструмента. */
export interface AgentHookRequest {
  kind: "agent-hook";
  /** `session_id` из stdin хука: он же `AgentSession.id`. */
  session: string;
  /** Каталог сессии из stdin хука; нет — каталог из реестра сессий. */
  cwd?: string;
  call: ToolCall;
}

/**
 * Обработчик хука чужих сессий — один на ядро. `signal` срабатывает, если мост оборвал соединение до
 * ответа: хук убит по `timeout` или человек ответил в терминале и CLI его завершил.
 */
export type AgentHookHandler = (request: AgentHookRequest, signal: AbortSignal) => Promise<AgentHookAnswer>;

/** Самая длинная строка запроса `agent-hook`, байт: больше человек в Luna не проверит, диалог остаётся в терминале. */
export const AGENT_HOOK_LINE_LIMIT = 1024 * 1024;

/** Обработчики вызовов одного запуска исполнителя. */
export interface ApprovalHandlers {
  /** Permission prompt: разрешить или отклонить, при необходимости спросив человека. */
  approve: (call: ToolCall) => Promise<Decision>;
  /** Хук `PreToolUse`: отказ либо «нет решения» — дальше решают режим CLI и permission prompt. */
  hook: (call: ToolCall) => Promise<HookDecision>;
}

export interface ApprovalSocketOptions {
  log?: (message: string) => void;
}

/** Ответ мосту и хуку, когда запуск уже завершился или не известен ядру. */
const UNKNOWN_RUN = { behavior: "deny", message: "Luna: задача уже завершена" } as const satisfies Decision & HookDecision;

export class ApprovalSocket {
  readonly path: string;
  private readonly server: Server;
  private readonly handlers = new Map<string, ApprovalHandlers>();
  private agentHook: AgentHookHandler | undefined;
  private readonly log: (message: string) => void;
  private closed = false;

  private constructor(path: string, server: Server, log: (message: string) => void) {
    this.path = path;
    this.server = server;
    this.log = log;
    server.on("connection", (socket) => this.serve(socket));
  }

  /**
   * Открывает сокет в `dataDir`, удалив файлы сокетов прежних запусков. Бросает ошибку, если
   * слушать не удалось — например, путь длиннее предела unix-сокета (на macOS 104 байта).
   */
  static async open(dataDir: string, options: ApprovalSocketOptions = {}): Promise<ApprovalSocket> {
    const log = options.log ?? (() => {});
    cleanupLeftovers(dataDir, log);
    const path = join(dataDir, `approvals-${randomBytes(8).toString("hex")}.sock`);
    const server = createServer();
    server.on("error", (error) => log(`сокет подтверждений: ${error.message}`));
    await new Promise<void>((resolve, reject) => {
      const fail = (error: Error) => reject(new Error(`сокет подтверждений ${path} не открылся: ${error.message}`));
      server.once("error", fail);
      server.listen(path, () => {
        server.off("error", fail);
        resolve();
      });
    });
    try {
      chmodSync(path, 0o600);
    } catch (error) {
      server.close();
      throw new Error(`сокету подтверждений не выставить права: ${describe(error)}`);
    }
    return new ApprovalSocket(path, server, log);
  }

  /** Подписывает запуск исполнителя на вызовы моста и хука; возвращает отписку. */
  register(run: string, handler: ApprovalHandlers): () => void {
    this.handlers.set(run, handler);
    return () => {
      if (this.handlers.get(run) === handler) this.handlers.delete(run);
    };
  }

  /** Обработчик хуков чужих сессий. Пока его нет, такие запросы получают «нет решения». */
  setAgentHook(handler: AgentHookHandler | undefined): void {
    this.agentHook = handler;
  }

  /** Закрывает сокет и удаляет его файл; повторный вызов ничего не делает. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.server.close();
    try {
      unlinkSync(this.path);
    } catch {
      // Файл уже снят сервером — это и нужно.
    }
  }

  private serve(socket: Socket): void {
    socket.setEncoding("utf8");
    let answered = false;
    const aborter = new AbortController();
    const answer = (decision: Decision | HookDecision | AgentHookAnswer) => {
      if (answered) return;
      answered = true;
      socket.end(`${JSON.stringify(decision)}\n`);
    };
    socket.on("error", (error) => this.log(`сокет подтверждений: соединение оборвано: ${error.message}`));
    // Мост ушёл, не дождавшись ответа: запрос чужой сессии снимается, а не висит до `shutdown()`.
    socket.on("close", () => {
      if (!answered) aborter.abort();
    });
    const lines = createInterface({ input: socket, crlfDelay: Infinity });
    // Ошибку сокета readline повторяет своим событием; её уже записали выше.
    lines.on("error", () => {});
    lines.once("line", (line) => {
      const request = parseRequest(line);
      if (!request) {
        this.log("сокет подтверждений: непонятный запрос моста");
        answer({ behavior: "deny", message: "Luna: непонятный запрос" });
        return;
      }
      if ("kind" in request && request.kind === "agent-hook") {
        this.serveAgentHook(line, request, aborter.signal, answer);
        return;
      }
      const handler = this.handlers.get(request.run);
      if (!handler) {
        answer(UNKNOWN_RUN);
        return;
      }
      const decision: Promise<Decision | HookDecision> = request.kind === "hook" ? handler.hook(request.call) : handler.approve(request.call);
      decision.then(answer, (error) => {
        this.log(`сокет подтверждений: ${describe(error)}`);
        answer({ behavior: "deny", message: `Luna: ${describe(error)}` });
      });
    });
  }

  /**
   * Хук чужой сессии. Любая беда здесь — «нет решения», а не отказ: отказ запретил бы действие, которое
   * человек разрешил бы в терминале.
   */
  private serveAgentHook(line: string, request: AgentHookRequest, signal: AbortSignal, answer: (decision: AgentHookAnswer) => void): void {
    const handler = this.agentHook;
    if (!handler || request.session === "" || Buffer.byteLength(line) > AGENT_HOOK_LINE_LIMIT) {
      answer({ behavior: "none" });
      return;
    }
    handler(request, signal).then(answer, (error) => {
      this.log(`сокет подтверждений: ${describe(error)}`);
      answer({ behavior: "none" });
    });
  }
}

function parseRequest(line: string): BridgeRequest | AgentHookRequest | undefined {
  let data: unknown;
  try {
    data = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (data === null || typeof data !== "object") return undefined;
  if ((data as { kind?: unknown }).kind === "agent-hook") return parseAgentHook(data as Record<string, unknown>);
  const { run, call, kind } = data as Partial<BridgeRequest>;
  if (typeof run !== "string" || call === null || typeof call !== "object") return undefined;
  if (typeof call.tool_name !== "string" || call.input === null || typeof call.input !== "object") return undefined;
  if (kind !== undefined && kind !== "approve" && kind !== "hook") return undefined;
  const result: BridgeRequest = { run, call: { tool_name: call.tool_name, input: call.input } };
  if (kind !== undefined) result.kind = kind;
  if (typeof call.tool_use_id === "string") result.call.tool_use_id = call.tool_use_id;
  return result;
}

/**
 * Запрос хука чужой сессии; непонятный запрос не отказ, а «нет решения»: сессию `""` обработчик не знает,
 * и мост получает `none`, а не `deny` от общего разбора.
 */
function parseAgentHook(data: Record<string, unknown>): AgentHookRequest {
  const { session, cwd, call } = data;
  const broken: AgentHookRequest = { kind: "agent-hook", session: "", call: { tool_name: "", input: {} } };
  if (typeof session !== "string" || session === "" || call === null || typeof call !== "object") return broken;
  const { tool_name: tool, input } = call as Partial<ToolCall>;
  if (typeof tool !== "string" || input === null || typeof input !== "object" || Array.isArray(input)) return broken;
  const request: AgentHookRequest = { kind: "agent-hook", session, call: { tool_name: tool, input } };
  if (typeof cwd === "string" && cwd !== "") request.cwd = cwd;
  return request;
}

function cleanupLeftovers(dataDir: string, log: (message: string) => void): void {
  let names: string[];
  try {
    names = readdirSync(dataDir);
  } catch {
    return;
  }
  for (const name of names) {
    if (!SOCKET_NAME.test(name)) continue;
    try {
      unlinkSync(join(dataDir, name));
    } catch (error) {
      log(`сокет подтверждений: остаток ${name} не удалён: ${describe(error)}`);
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
