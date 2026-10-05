import type { AgentSession, AgentStep } from "../rpc/protocol.gen.ts";
import type { AgentSource } from "./source.ts";

export interface AgentMonitorOptions {
  sources: AgentSource[];
  /** Как часто перечитываются источники. */
  intervalMs?: number;
  /** Зовётся, когда список сессий изменился. */
  emit: (sessions: AgentSession[]) => void;
  log?: (message: string) => void;
}

/** Опрашивает источники сессий и сообщает оболочке об изменениях полным списком. */
export class AgentMonitor {
  private readonly options: AgentMonitorOptions;
  private current: AgentSession[] = [];
  private snapshot = "[]";
  private timer: NodeJS.Timeout | undefined;
  private refreshing: Promise<void> | undefined;
  /** Уведомления идут только подписчику: оболочке, которая уже запросила список. */
  private subscribed = false;

  constructor(options: AgentMonitorOptions) {
    this.options = options;
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
    const snapshot = JSON.stringify(sessions);
    if (snapshot === this.snapshot) return;
    this.current = sessions;
    this.snapshot = snapshot;
    if (this.subscribed) this.options.emit(sessions);
  }
}
