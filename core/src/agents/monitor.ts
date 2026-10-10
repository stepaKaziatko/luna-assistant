import type { AgentSession, AgentStep } from "../rpc/protocol.gen.ts";
import type { AgentApprovals } from "./approvals.ts";
import type { AgentSource } from "./source.ts";

export interface AgentMonitorOptions {
  sources: AgentSource[];
  /** Как часто перечитываются источники. */
  intervalMs?: number;
  /** Зовётся, когда список сессий изменился. */
  emit: (sessions: AgentSession[]) => void;
  log?: (message: string) => void;
  /**
   * Запросы подтверждения от хуков чужих сессий. Монитор только подмешивает их в сессии и сверяет со
   * свежим списком; источники по-прежнему только читают.
   */
  approvals?: AgentApprovals;
}

/** Опрашивает источники сессий и сообщает оболочке об изменениях полным списком. */
export class AgentMonitor {
  private readonly options: AgentMonitorOptions;
  /** Сессии источников как есть, без запросов подтверждения. */
  private base: AgentSession[] = [];
  private current: AgentSession[] = [];
  private snapshot = "[]";
  private timer: NodeJS.Timeout | undefined;
  private refreshing: Promise<void> | undefined;
  /** Уведомления идут только подписчику: оболочке, которая уже запросила список. */
  private subscribed = false;

  constructor(options: AgentMonitorOptions) {
    this.options = options;
    // Запрос появился или снят — оболочка узнаёт сразу, не ждёт такта опроса.
    options.approvals?.subscribe(() => this.publish());
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.refresh(), this.options.intervalMs ?? 1000);
    // Опрос не держит процесс живым: ядро завершается, когда закрылся stdin.
    this.timer.unref();
  }

  stop(): void {
    clearInterval(this.timer);
    this.timer = undefined;
  }

  /** Свежий список; с первого вызова оболочка получает и уведомления об изменениях. */
  async list(): Promise<AgentSession[]> {
    await this.refresh();
    this.subscribed = true;
    return this.current;
  }

  /** Сессия по id из последнего прохода; нет — один свежий проход (сессия могла появиться только что). */
  async find(sessionId: string): Promise<AgentSession | undefined> {
    const known = this.base.find((session) => session.id === sessionId);
    if (known) return known;
    await this.refresh();
    return this.base.find((session) => session.id === sessionId);
  }

  async steps(sessionId: string, detail = false): Promise<AgentStep[]> {
    for (const source of this.options.sources) {
      const steps = await source.steps(sessionId, detail);
      if (steps) return steps;
    }
    return [];
  }

  /** Параллельные вызовы ждут один и тот же проход. */
  refresh(): Promise<void> {
    this.refreshing ??= this.collect().finally(() => {
      this.refreshing = undefined;
    });
    return this.refreshing;
  }

  private async collect(): Promise<void> {
    const lists = await Promise.all(
      this.options.sources.map((source) =>
        source.sessions().catch((error) => {
          this.options.log?.(`agent source ${source.agent} failed: ${String(error)}`);
          return [] as AgentSession[];
        }),
      ),
    );
    // Порядок стабильный: проекты по алфавиту, внутри проекта — по времени старта.
    const sessions = lists
      .flat()
      .sort((a, b) => a.project.localeCompare(b.project) || a.startedAt - b.startedAt || a.id.localeCompare(b.id));
    this.base = sessions;
    // Запрос, чью сессию ответ в терминале или завершение уже сняли, уходит до рассылки снимка.
    this.options.approvals?.reconcile(sessions);
    this.publish();
  }

  /** Снимок с запросами подтверждения; рассылается, только если изменился. */
  private publish(): void {
    const sessions = this.options.approvals ? this.options.approvals.attach(this.base) : this.base;
    const snapshot = JSON.stringify(sessions);
    if (snapshot === this.snapshot) return;
    this.current = sessions;
    this.snapshot = snapshot;
    if (this.subscribed) this.options.emit(sessions);
  }
}
