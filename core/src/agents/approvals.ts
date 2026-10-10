import { randomUUID } from "node:crypto";
import type { PauseRequest } from "../executors/executor.ts";
import type { AgentSession, ApprovalRequest } from "../rpc/protocol.gen.ts";

// Подтверждения действий чужих сессий агентов. Источник запроса — хук, который поставил сам
// пользователь, а не файлы сессии: `AgentSource` остаётся только чтением. Менеджер держит запросы по
// сессиям, отдаёт самый ранний сессии как `AgentSession.approval` и возвращает хуку решение человека.
// Решает человек или терминал сессии: запрос Luna — второй способ ответить, а не замена первого.

/** Что получает хук: решение человека либо «нет решения» (диалог остаётся в терминале). */
export type AgentApprovalOutcome = "allow" | "deny" | "none";

/** Ответ на `agents.approve` не по адресу: сессия неизвестна, запроса нет или `approvalId` устарел. */
export class AgentApprovalError extends Error {}

interface Pending {
  approval: ApprovalRequest;
  settle: (outcome: AgentApprovalOutcome) => void;
  /** Сессия побывала в `waiting` после появления запроса: дальше выход из `waiting` — ответ в терминале. */
  seenWaiting: boolean;
  /**
   * `updatedAt` сессии, пока она ждала этот запрос: у каждого диалога разрешения своя запись реестра.
   * Параллельные вызовы инструментов дают несколько хуков сразу, а диалоги CLI показывает по одному, поэтому
   * сменившаяся запись при нескольких запросах — самый ранний диалог уже закрыт.
   */
  episode?: number;
}

export class AgentApprovals {
  private readonly queues = new Map<string, Pending[]>();
  private readonly listeners = new Set<() => void>();
  private closed = false;

  /** Зовётся при любом изменении запросов: появился, снят, отвечен. */
  subscribe(listener: () => void): void {
    this.listeners.add(listener);
  }

  /**
   * Ставит запрос на сессию и ждёт решения. Запрос снимается ответом человека, пропажей сессии,
   * выходом из `waiting` без ответа Luna (ответили в терминале), обрывом хука (`signal`) и `shutdown()`:
   * в этих случаях результат — `none`.
   */
  ask(sessionId: string, request: PauseRequest, signal?: AbortSignal): Promise<AgentApprovalOutcome> {
    if (this.closed || signal?.aborted) return Promise.resolve("none");
    const approval: ApprovalRequest = {
      id: randomUUID(),
      tool: request.tool,
      kind: request.kind,
      summary: request.summary,
      createdAt: Date.now(),
    };
    if (request.target !== undefined) approval.target = request.target;
    if (request.detail !== undefined) approval.detail = request.detail;
    return new Promise((resolve) => {
      let settled = false;
      const pending: Pending = {
        approval,
        seenWaiting: false,
        settle: (outcome) => {
          if (settled) return;
          settled = true;
          signal?.removeEventListener("abort", onAbort);
          resolve(outcome);
        },
      };
      const onAbort = () => {
        if (this.remove(sessionId, pending)) this.notify();
        pending.settle("none");
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      const queue = this.queues.get(sessionId) ?? [];
      queue.push(pending);
      this.queues.set(sessionId, queue);
      this.notify();
    });
  }

  /** Ответ человека. Бросает `AgentApprovalError`, если сессия неизвестна, запроса нет или id устарел. */
  approve(sessionId: string, approvalId: string, allow: boolean): void {
    const head = this.queues.get(sessionId)?.[0];
    if (!head) throw new AgentApprovalError(`session is not waiting for approval: ${sessionId}`);
    if (head.approval.id !== approvalId) throw new AgentApprovalError(`approval is outdated: ${approvalId}`);
    this.remove(sessionId, head);
    head.settle(allow ? "allow" : "deny");
    this.notify();
  }

  /**
   * Сверяет запросы со свежим списком сессий: пропавшая сессия и сессия, которая ушла из `waiting`
   * после того, как была в нём, — запросы сняты. Возвращает true, если что-то снято.
   */
  reconcile(sessions: AgentSession[]): boolean {
    if (this.queues.size === 0) return false;
    const byId = new Map(sessions.map((session) => [session.id, session]));
    let changed = false;
    for (const [sessionId, queue] of [...this.queues]) {
      const session = byId.get(sessionId);
      if (session?.state === "waiting") {
        for (const pending of queue) pending.seenWaiting = true;
        const head = queue[0];
        if (head && head.episode === undefined) head.episode = session.updatedAt;
        // Диалог закрыт в терминале, и CLI показал следующий: прежний запрос Luna больше ни о чём не спрашивает.
        while (queue.length > 1 && queue[0]?.episode !== undefined && queue[0].episode !== session.updatedAt) {
          queue.shift()?.settle("none");
          const next = queue[0];
          if (next) next.episode = session.updatedAt;
          changed = true;
        }
        continue;
      }
      // Состояние не `waiting`: сессии нет, либо она ответила на диалог в терминале. Пока в `waiting` её
      // не видели, запрос свежий — реестр мог отстать от хука, ждём.
      if (session && !queue.some((pending) => pending.seenWaiting)) continue;
      this.queues.delete(sessionId);
      for (const pending of queue) pending.settle("none");
      changed = true;
    }
    return changed;
  }

  /** Список сессий с `approval` у тех, чей запрос ждёт; исходные объекты не меняются. */
  attach(sessions: AgentSession[]): AgentSession[] {
    if (this.queues.size === 0) return sessions;
    return sessions.map((session) => {
      const head = this.queues.get(session.id)?.[0];
      return head ? { ...session, approval: head.approval } : session;
    });
  }

  /** Снимает все запросы без решения: соединения хуков закрываются, диалоги остаются в терминалах. */
  shutdown(): void {
    this.closed = true;
    const queues = [...this.queues.values()];
    this.queues.clear();
    for (const queue of queues) for (const pending of queue) pending.settle("none");
  }

  private remove(sessionId: string, pending: Pending): boolean {
    const queue = this.queues.get(sessionId);
    const index = queue?.indexOf(pending) ?? -1;
    if (!queue || index < 0) return false;
    queue.splice(index, 1);
    if (queue.length === 0) this.queues.delete(sessionId);
    return true;
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}
