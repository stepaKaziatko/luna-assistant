import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import { ErrorCode, RpcError, RpcServer } from "../src/rpc/jsonrpc.ts";

async function exchange(configure: (server: RpcServer) => void, lines: string[]): Promise<unknown[]> {
  const input = new PassThrough();
  const output = new PassThrough();
  const server = new RpcServer(input, output);
  configure(server);

  const listening = server.listen();
  for (const line of lines) input.write(line + "\n");
  input.end();
  await listening;
  await new Promise((resolve) => setTimeout(resolve, 10));

  const written = (output.read() as Buffer | null)?.toString("utf8") ?? "";
  return written.split("\n").filter(Boolean).map((line) => JSON.parse(line) as unknown);
}

test("отвечает на запрос результатом обработчика", async () => {
  const messages = await exchange(
    (server) => server.method("echo", async (params) => ({ got: params })),
    ['{"jsonrpc":"2.0","id":1,"method":"echo","params":{"a":1}}'],
  );
  assert.deepEqual(messages, [{ jsonrpc: "2.0", id: 1, result: { got: { a: 1 } } }]);
});

test("ошибки: неизвестный метод, RpcError, исключение, битый JSON", async () => {
  const messages = await exchange(
    (server) => {
      server.method("invalid", () => {
        throw new RpcError(ErrorCode.InvalidParams, "bad params");
      });
      server.method("crash", () => {
        throw new Error("boom");
      });
    },
    [
      '{"jsonrpc":"2.0","id":1,"method":"nope"}',
      '{"jsonrpc":"2.0","id":2,"method":"invalid"}',
      '{"jsonrpc":"2.0","id":3,"method":"crash"}',
      "{broken",
    ],
  );
  assert.deepEqual(messages, [
    { jsonrpc: "2.0", id: 1, error: { code: -32601, message: "Method not found: nope" } },
    { jsonrpc: "2.0", id: 2, error: { code: -32602, message: "bad params" } },
    { jsonrpc: "2.0", id: 3, error: { code: -32603, message: "boom" } },
    { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } },
  ]);
});

test("уведомления: входящие без ответа, исходящие без id", async () => {
  const seen: unknown[] = [];
  const messages = await exchange(
    (server) => {
      server.method("ping", (params) => {
        seen.push(params);
        server.notify("pong", { ok: true });
      });
    },
    ['{"jsonrpc":"2.0","method":"ping","params":{"n":1}}'],
  );
  assert.deepEqual(seen, [{ n: 1 }]);
  assert.deepEqual(messages, [{ jsonrpc: "2.0", method: "pong", params: { ok: true } }]);
});
