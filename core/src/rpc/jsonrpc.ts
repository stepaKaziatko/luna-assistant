import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";

// JSON-RPC 2.0 поверх stdio: одно сообщение — одна строка JSON.

export const ErrorCode = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
} as const;

export class RpcError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

type Handler = (params: unknown) => unknown | Promise<unknown>;

interface Incoming {
  jsonrpc?: unknown;
  id?: unknown;
  method?: unknown;
  params?: unknown;
}

export class RpcServer {
  private readonly handlers = new Map<string, Handler>();
  private readonly input: Readable;
  private readonly output: Writable;

  constructor(input: Readable, output: Writable) {
    this.input = input;
    this.output = output;
  }

  method(name: string, handler: Handler): void {
    this.handlers.set(name, handler);
  }

  notify(method: string, params: unknown): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  /** Обрабатывает входящие сообщения, пока входной поток не закроется. */
  async listen(): Promise<void> {
    const lines = createInterface({ input: this.input, crlfDelay: Infinity });
    for await (const line of lines) {
      if (line.trim() === "") continue;
      void this.dispatch(line);
    }
  }

  private async dispatch(line: string): Promise<void> {
    let message: Incoming;
    try {
      message = JSON.parse(line) as Incoming;
    } catch {
      this.writeError(null, ErrorCode.ParseError, "Parse error");
      return;
    }
    if (message === null || typeof message !== "object" || typeof message.method !== "string") {
      this.writeError(null, ErrorCode.InvalidRequest, "Invalid request");
      return;
    }

    const id = typeof message.id === "number" || typeof message.id === "string" ? message.id : undefined;
    const handler = this.handlers.get(message.method);
    if (!handler) {
      if (id !== undefined) this.writeError(id, ErrorCode.MethodNotFound, `Method not found: ${message.method}`);
      return;
    }

    try {
      const result = await handler(message.params);
      if (id !== undefined) this.write({ jsonrpc: "2.0", id, result: result ?? null });
    } catch (error) {
      if (id === undefined) return;
      if (error instanceof RpcError) this.writeError(id, error.code, error.message);
      else this.writeError(id, ErrorCode.InternalError, error instanceof Error ? error.message : String(error));
    }
  }

  private writeError(id: number | string | null, code: number, message: string): void {
    this.write({ jsonrpc: "2.0", id, error: { code, message } });
  }

  private write(message: unknown): void {
    this.output.write(JSON.stringify(message) + "\n");
  }
}
