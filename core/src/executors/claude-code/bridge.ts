import { appendFileSync } from "node:fs";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";

// Мост между Claude Code и ядром: MCP-сервер на stdio с одним инструментом `approve`.
// CLI запускает его сам (`--mcp-config`) и зовёт инструмент перед действием, которое не разрешено
// (`--permission-prompt-tool mcp__luna__approve`), с `{ tool_name, input, tool_use_id }`; ответ —
// текст JSON `{"behavior":"allow","updatedInput":…}` либо `{"behavior":"deny","message":…}`.
// Решение мост получает от ядра по unix-сокету (socket.ts). Зависимостей нет: протокол MCP здесь —
// несколько методов JSON-RPC 2.0 построчно. Формат сверен с Claude Code 2.1.181.
//
//   node bridge.js <путь к сокету ядра> <id запуска исполнителя>
//
// stdout занят протоколом MCP — диагностика только в stderr. LUNA_BRIDGE_TRACE=<файл> — дописывать
// туда входящие строки CLI: так снимаются фикстуры для core/test/bridge.test.ts.

const SERVER_NAME = "luna";
const TOOL_NAME = "approve";
/** Версия протокола MCP, которую мост называет, если клиент свою не сообщил. */
const DEFAULT_PROTOCOL_VERSION = "2024-11-05";

const [socketPath, runId] = process.argv.slice(2);
if (!socketPath || !runId) {
  process.stderr.write("[luna-bridge] нужны аргументы: <сокет> <id запуска>\n");
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

/** Один вызов инструмента — одно соединение с ядром: строка запроса, строка ответа. */
function askCore(call: Record<string, unknown>): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (decision: Record<string, unknown>) => {
      if (settled) return;
      settled = true;
      resolve(decision);
    };
    const socket = createConnection(socketPath as string);
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
    socket.write(`${JSON.stringify({ run: runId, call })}\n`);
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

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  if (line.trim() === "") continue;
  if (trace) {
    try {
      appendFileSync(trace, `${line}\n`);
    } catch {
      // Трассировка — только для снятия фикстур; её сбой мост не останавливает.
    }
  }
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
