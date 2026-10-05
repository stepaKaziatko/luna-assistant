import type { AgentSession, AgentStep } from "../rpc/protocol.gen.ts";

/**
 * Сессии агента, запущенные не Luna: в редакторе, в терминале. Luna за ними только наблюдает.
 * Особенности конкретного агента — где он хранит сессии и журналы — не выходят за его источник.
 */
export interface AgentSource {
  /** Значение `AgentSession.agent` у сессий этого источника. */
  readonly agent: string;
  /** Живые сессии на этой машине. Сбой чтения — пустой список, а не исключение. */
  sessions(): Promise<AgentSession[]>;
  /**
   * Последние шаги сессии, старые первыми; undefined — сессия не из этого источника.
   * `detail` — подробная лента: больше шагов, текст длиннее и с переносами строк.
   */
  steps(sessionId: string, detail?: boolean): Promise<AgentStep[] | undefined>;
}
