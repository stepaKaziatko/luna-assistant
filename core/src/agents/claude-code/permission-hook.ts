import { isAbsolute, resolve, sep } from "node:path";
import { HOOK_MATCHER } from "../../executors/claude-code/adapter.ts";
import { AGENT_DENIED_MESSAGE, AGENT_HOOK_NONE, describeApproval, tooLongToShow, type AgentHookAnswer } from "../../executors/claude-code/approval.ts";
import type { AgentHookHandler } from "../../executors/claude-code/socket.ts";
import type { AgentSession } from "../../rpc/protocol.gen.ts";
import type { AgentApprovals } from "../approvals.ts";

// Хук `PermissionRequest` чужой сессии Claude Code: CLI показал диалог разрешения и параллельно
// спросил хук, который поставил пользователь (bridge.ts, режим `agent-hook`). Здесь решается, показывать
// ли запрос человеку в Luna. «Нет решения» — диалог остаётся в терминале; отказом Luna за терминал
// не отвечает никогда, кроме явного «Отклонить» человека.

/** Инструменты, о которых Luna спрашивает человека: те же, что в матчере хука задач. */
const TOOLS = new Set(HOOK_MATCHER.split("|"));

export interface PermissionHookOptions {
  approvals: AgentApprovals;
  /** Наблюдаемая сессия по id; неизвестная ядру сессия «нет решения». */
  find: (sessionId: string) => Promise<AgentSession | undefined>;
  /** Каталоги задач самой Luna: их сессии наблюдаемыми не бывают, а запрос оттуда — не от чужой сессии. */
  excludeCwd: string[];
}

export function permissionHook(options: PermissionHookOptions): AgentHookHandler {
  const excluded = options.excludeCwd.map((dir) => resolve(dir) + sep);
  const inside = (cwd: string) => {
    const path = resolve(cwd) + sep;
    return excluded.some((dir) => path.startsWith(dir));
  };
  return async (request, signal): Promise<AgentHookAnswer> => {
    if (!TOOLS.has(request.call.tool_name)) return AGENT_HOOK_NONE;
    // Команду, которую человек целиком не прочтёт, Luna не решает: в терминале диалог на месте.
    if (tooLongToShow(request.call)) return AGENT_HOOK_NONE;
    const session = await options.find(request.session);
    if (!session) return AGENT_HOOK_NONE;
    // Каталог сессии из запроса хука точнее реестра: сессия могла сделать `cd`.
    const cwd = request.cwd && isAbsolute(request.cwd) ? request.cwd : session.cwd;
    if (inside(cwd) || inside(session.cwd)) return AGENT_HOOK_NONE;
    const outcome = await options.approvals.ask(session.id, describeApproval(request.call, cwd, "session"), signal);
    if (outcome === "allow") return { behavior: "allow" };
    if (outcome === "deny") return { behavior: "deny", message: AGENT_DENIED_MESSAGE };
    return AGENT_HOOK_NONE;
  };
}
