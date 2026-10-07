import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after } from "node:test";
import { ApprovalSocket } from "../../src/executors/claude-code/socket.ts";

/** Канал подтверждений во временном каталоге для тестов адаптера; закрывается по окончании файла тестов. */
export async function openTestApprovals(): Promise<ApprovalSocket> {
  const approvals = await ApprovalSocket.open(mkdtempSync(join(tmpdir(), "luna-approvals-")));
  after(() => approvals.close());
  return approvals;
}
