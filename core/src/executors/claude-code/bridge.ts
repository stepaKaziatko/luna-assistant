import { appendFileSync } from "node:fs";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";

// Мост между Claude Code и ядром. Решения по вызовам инструментов мост получает от ядра по
// unix-сокету (socket.ts): одно соединение на вызов, строка запроса — строка ответа. Зависимостей
// нет. Режимов два, оба запускает сам CLI:
//
//   node bridge.js <путь к сокету ядра> <id запуска исполнителя>
//
// MCP-сервер на stdio с одним инструментом `approve` (`--mcp-config`). CLI зовёт его перед действием,
// которое не разрешено (`--permission-prompt-tool mcp__luna__approve`), с `{ tool_name, input,
// tool_use_id }`; ответ — текст JSON `{"behavior":"allow","updatedInput":…}` либо
// `{"behavior":"deny","message":…}`. Протокол MCP здесь — несколько методов JSON-RPC 2.0 построчно.
// Формат сверен с Claude Code 2.1.181.
//
//   node bridge.js hook <путь к сокету ядра> <id запуска исполнителя>
//
// Хук `PreToolUse` (`--settings`, см. `hookSettings` в adapter.ts). CLI зовёт его перед каждым вызовом
// записи и команд — раньше своего режима разрешений, поэтому хук держит веб-запрет и там, где режим
// пропустил бы действие без вопроса. В stdin — JSON вызова (`tool_name`, `tool_input`, `tool_use_id`);
// ядро решает без человека: отказ либо «нет решения». Отказ — JSON `hookSpecificOutput` с
// `permissionDecision: "deny"` и причиной; «нет решения» — пустой вывод и код 0 (не `allow`: тот
// отменил бы вопросы режима). Свою беду хук считает отказом: ядро недоступно, ответ непонятен или не
// пришёл вовремя — `deny`; вход не разобран — код 2 (CLI блокирует вызов).
//
// stdout занят протоколом MCP и ответом хука — диагностика только в stderr. LUNA_BRIDGE_TRACE=<файл> —
// дописывать туда входящие строки CLI (у хука — его stdin одной строкой): так снимаются фикстуры для
// core/test/bridge.test.ts.

const SERVER_NAME = "luna";
const TOOL_NAME = "approve";
/** Версия протокола MCP, которую мост называет, если клиент свою не сообщил. */
const DEFAULT_PROTOCOL_VERSION = "2024-11-05";
/**
 * Сколько хук ждёт решения ядра. Короче `timeout` хука в `--settings` (adapter.ts `HOOK_TIMEOUT_S`):
 * истёкший таймаут команды CLI считает неблокирующей ошибкой и пропускает вызов, а свой срок хук
 * закрывает отказом. Ядро само ждёт строку вызова не дольше `TOOL_USE_WAIT_MS` (5 с).
 */
const HOOK_WAIT_MS = 20_000;

const args = process.argv.slice(2);
const hookMode = args[0] === "hook";
const [socketPath, runId] = hookMode ? args.slice(1) : args;
if (!socketPath || !runId) {
  process.stderr.write("[luna-bridge] нужны аргументы: [hook] <сокет> <id запуска>\n");
  process.exit(2);
}
const trace = process.env.LUNA_BRIDGE_TRACE;

interface Incoming {
  id?: unknown;
  method?: unknown;
  params?: unknown;
}

const write = (message: unknown) => process.stdout.write(`${JSON.stringify(message)}\n`);
const log = (message: string) => process.stderr.write(`[luna-bridge] ${message}\n`);

/** Решение, которое получает CLI, когда ядро недоступно: действие не выполняется. */
const unavailable = (reason: string) => ({ behavior: "deny", message: `Luna недоступна: ${reason}` });

/**
 * Один вызов инструмента — одно соединение с ядром: строка запроса, строка ответа. `kind: "hook"` —
 * запрос хука; без поля — запрос permission prompt. `waitMs` — срок ответа, по истечении — отказ.
 */
function askCore(call: Record<string, unknown>, kind?: "hook", waitMs?: number): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (decision: Record<string, unknown>) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(decision);
    };
    const socket = createConnection(socketPath as string);
    if (waitMs !== undefined) {
      timer = setTimeout(() => {
        finish(unavailable("ядро не ответило вовремя"));
        socket.destroy();
      }, waitMs);
    }
    socket.setEncoding("utf8");
    socket.on("error", (error) => finish(unavailable(error.message)));
    socket.on("close", () => finish(unavailable("ядро закрыло соединение без ответа")));
    const lines = createInterface({ input: socket, crlfDelay: Infinity });
    // Ошибку сокета readline повторяет своим событием; её уже обработали выше.
    lines.on("error", () => {});
    lines.once("line", (line) => {
      try {
        const decision = JSON.parse(line) as Record<string, unknown>;
        finish(decision && typeof decision === "object" ? decision : unavailable("непонятный ответ ядра"));
      } catch {
        finish(unavailable("непонятный ответ ядра"));
      }
      socket.end();
    });
    socket.write(`${JSON.stringify({ run: runId, call, ...(kind ? { kind } : {}) })}\n`);
  });
}

async function handle(message: Incoming): Promise<void> {
  const id = typeof message.id === "number" || typeof message.id === "string" ? message.id : undefined;
  const params = (message.params ?? {}) as Record<string, unknown>;
  const reply = (result: unknown) => {
    if (id !== undefined) write({ jsonrpc: "2.0", id, result });
  };

  switch (message.method) {
    case "initialize":
      reply({
        protocolVersion: typeof params.protocolVersion === "string" ? params.protocolVersion : DEFAULT_PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: "1" },
      });
      return;
    case "ping":
      reply({});
      return;
    case "tools/list":
      reply({
        tools: [
          {
            name: TOOL_NAME,
            description: "Спрашивает у человека в Luna разрешение на действие исполнителя.",
            inputSchema: {
              type: "object",
              properties: {
                tool_name: { type: "string" },
                input: { type: "object" },
                tool_use_id: { type: "string" },
              },
              required: ["tool_name", "input"],
            },
          },
        ],
      });
      return;
    case "tools/call": {
      const args = (params.arguments ?? {}) as Record<string, unknown>;
      if (params.name !== TOOL_NAME) {
        if (id !== undefined) write({ jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${String(params.name)}` } });
        return;
      }
      const call: Record<string, unknown> = {
        tool_name: typeof args.tool_name === "string" ? args.tool_name : "",
        input: args.input !== null && typeof args.input === "object" ? args.input : {},
      };
      if (typeof args.tool_use_id === "string") call.tool_use_id = args.tool_use_id;
      const decision = await askCore(call);
      reply({ content: [{ type: "text", text: JSON.stringify(decision) }] });
      return;
    }
    default:
      // Уведомления (`notifications/initialized`) ответа не ждут; незнакомый запрос — ошибка.
      if (id !== undefined) write({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${String(message.method)}` } });
  }
}

/** Строка трассировки для снятия фикстур; её сбой мост не останавливает. */
function traceLine(line: string): void {
  if (!trace) return;
  try {
    appendFileSync(trace, `${line}\n`);
  } catch {
    // Трассировка — только для снятия фикстур.
  }
}

async function serveMcp(): Promise<void> {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    if (line.trim() === "") continue;
    traceLine(line);
    let message: Incoming;
    try {
      message = JSON.parse(line) as Incoming;
    } catch {
      write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
      continue;
    }
    if (message === null || typeof message !== "object" || typeof message.method !== "string") {
      write({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid request" } });
      continue;
    }
    // Вызовы обрабатываются по очереди: CLI ждёт ответа на permission prompt, прежде чем идти дальше.
    try {
      await handle(message);
    } catch (error) {
      log(error instanceof Error ? error.message : String(error));
    }
  }
}

/** Ответ хука `PreToolUse` с отказом: CLI не выполняет вызов и передаёт причину модели. */
function hookDeny(reason: string): void {
  write({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } });
}

async function runHook(): Promise<void> {
  let raw = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) raw += chunk as string;
  traceLine(raw.trim());
  let input: Record<string, unknown>;
  try {
    const data = JSON.parse(raw) as unknown;
    if (data === null || typeof data !== "object" || Array.isArray(data)) throw new Error("вход хука — не объект");
    input = data as Record<string, unknown>;
  } catch (error) {
    // Код 2 — блокирующая ошибка хука: CLI вызов не выполняет, текст stderr уходит модели.
    // Выход — естественный, а не `process.exit`: на macOS запись в канал асинхронная и оборвалась бы.
    process.stderr.write(`Luna: вход хука не разобран (${error instanceof Error ? error.message : String(error)}), действие не выполнено\n`);
    process.exitCode = 2;
    return;
  }
  const call: Record<string, unknown> = {
    tool_name: typeof input.tool_name === "string" ? input.tool_name : "",
    input: input.tool_input !== null && typeof input.tool_input === "object" ? input.tool_input : {},
  };
  if (typeof input.tool_use_id === "string") call.tool_use_id = input.tool_use_id;
  const decision = await askCore(call, "hook", HOOK_WAIT_MS);
  if (decision.behavior === "defer") return;
  hookDeny(typeof decision.message === "string" && decision.message !== "" ? decision.message : "Luna: действие не выполнено");
}

if (hookMode) {
  try {
    await runHook();
  } catch (error) {
    // Беда самого хука — отказ: без решения ядра вызов записи не проходит.
    hookDeny(`Luna: хук не сработал (${error instanceof Error ? error.message : String(error)}), действие не выполнено`);
  }
} else {
  await serveMcp();
}
