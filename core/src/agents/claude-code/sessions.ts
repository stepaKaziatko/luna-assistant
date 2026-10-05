import { open, readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve, sep } from "node:path";
import type { AgentHost, AgentSession, AgentState, AgentStep } from "../../rpc/protocol.gen.ts";
import { hostOf, readProcessTable, type ProcessTable } from "../host.ts";
import type { AgentSource } from "../source.ts";
import { appendTranscript, DETAILED, summarizeTranscript, type TranscriptSummary } from "./transcript.ts";

// Живые сессии Claude Code. CLI сам ведёт их реестр: ~/.claude/sessions/<pid>.json
// со статусом, рабочей директорией и точкой входа; журнал сессии лежит в ~/.claude/projects.
// Формат сверен с Claude Code 2.1.288.

/** Запись реестра сессий — только поля, которые читает Luna. */
interface RegistryEntry {
  pid?: unknown;
  sessionId?: unknown;
  cwd?: unknown;
  startedAt?: unknown;
  kind?: unknown;
  entrypoint?: unknown;
  status?: unknown;
  waitingFor?: unknown;
  statusUpdatedAt?: unknown;
  updatedAt?: unknown;
}

export interface ClaudeSessionsOptions {
  /** Каталог настроек Claude Code; по умолчанию ~/.claude. */
  home?: string;
  /** Сессии с рабочей директорией внутри этих каталогов не показываются: это задачи самой Luna. */
  excludeCwd?: string[];
  isAlive?: (pid: number) => boolean;
  processTable?: () => Promise<ProcessTable>;
}

/**
 * Хвоста журнала хватает на последние шаги: заголовок сессии CLI переписывает после каждого хода.
 * Запас — на длинные записи: результаты инструментов с файлами и картинками лежат в журнале целиком.
 */
const TAIL_BYTES = 2 * 1024 * 1024;

/** Сколько последних шагов едет в самой сессии — на превью работы в шторке. */
export const TRAIL_LIMIT = 6;

/** Схема ссылки, по которой расширение Claude Code открывает сессию в своём редакторе. */
const URL_SCHEMES: Record<string, string> = {
  "Visual Studio Code": "vscode",
  "Visual Studio Code - Insiders": "vscode-insiders",
  VSCodium: "vscodium",
  Cursor: "cursor",
  Windsurf: "windsurf",
};

interface CachedTranscript {
  path: string;
  size: number;
  mtimeMs: number;
  /** Сколько байт журнала уже разобрано: до конца последней полной строки. */
  offset: number;
  summary: TranscriptSummary;
}

export function defaultClaudeHome(): string {
  return process.env.LUNA_CLAUDE_HOME ?? process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude");
}

export class ClaudeCodeSessions implements AgentSource {
  readonly agent = "claude-code";

  private readonly home: string;
  private readonly excluded: string[];
  private readonly isAlive: (pid: number) => boolean;
  private readonly processTable: () => Promise<ProcessTable>;
  private readonly transcripts = new Map<string, CachedTranscript>();
  /** Хозяин процесса не меняется, пока процесс жив; ключ — pid и время старта сессии. */
  private readonly hosts = new Map<string, AgentHost>();

  constructor(options: ClaudeSessionsOptions = {}) {
    this.home = options.home ?? defaultClaudeHome();
    this.excluded = (options.excludeCwd ?? []).map((dir) => resolve(dir) + sep);
    this.isAlive = options.isAlive ?? processIsAlive;
    this.processTable = options.processTable ?? readProcessTable;
  }

  async sessions(): Promise<AgentSession[]> {
    const entries = await this.readRegistry();
    // Таблица процессов нужна только новым сессиям; на всех она одна.
    let table: Promise<ProcessTable> | undefined;
    let workspaces: Promise<string[]> | undefined;
    const sessions = await Promise.all(
      entries.map(async (entry) => {
        const hostKey = `${entry.pid}:${entry.startedAt}`;
        let host = this.hosts.get(hostKey);
        if (!host) {
          table ??= this.processTable();
          workspaces ??= this.readWorkspaces();
          host = hostFor(entry, await table, await workspaces);
          this.hosts.set(hostKey, host);
        }
        return this.describe(entry, host);
      }),
    );

    const live = new Set(entries.map((entry) => entry.sessionId));
    for (const id of this.transcripts.keys()) if (!live.has(id)) this.transcripts.delete(id);
    const liveHosts = new Set(entries.map((entry) => `${entry.pid}:${entry.startedAt}`));
    for (const key of this.hosts.keys()) if (!liveHosts.has(key)) this.hosts.delete(key);
    return sessions;
  }

  async steps(sessionId: string, detail = false): Promise<AgentStep[] | undefined> {
    const cached = this.transcripts.get(sessionId);
    if (!cached || !detail) return cached?.summary.steps;
    // Подробная лента нужна редко — окну сессии; журнал перечитывается по запросу и в памяти не держится.
    try {
      const info = await stat(cached.path);
      return summarizeTranscript((await readTail(cached.path, info.size)).lines, DETAILED).steps;
    } catch {
      return cached.summary.steps;
    }
  }

  private async readRegistry(): Promise<ValidEntry[]> {
    const dir = join(this.home, "sessions");
    let names: string[];
    try {
      names = await readdir(dir);
    } catch {
      return [];
    }
    const entries = await Promise.all(
      names
        .filter((name) => /^\d+\.json$/.test(name))
        .map(async (name) => {
          try {
            return validate(JSON.parse(await readFile(join(dir, name), "utf8")) as RegistryEntry);
          } catch {
            // Файл могли удалить или не дописать — сессия появится на следующем проходе.
            return undefined;
          }
        }),
    );
    return entries.filter((entry): entry is ValidEntry => {
      if (!entry || !this.isAlive(entry.pid)) return false;
      const cwd = resolve(entry.cwd) + sep;
      return !this.excluded.some((dir) => cwd.startsWith(dir));
    });
  }

  /**
   * Папки, открытые в окнах редакторов: расширение Claude Code записывает их в ~/.claude/ide/*.lock.
   * Из файла читается только список папок.
   */
  private async readWorkspaces(): Promise<string[]> {
    const dir = join(this.home, "ide");
    try {
      const names = (await readdir(dir)).filter((name) => name.endsWith(".lock"));
      const lists = await Promise.all(
        names.map(async (name) => {
          try {
            const lock = JSON.parse(await readFile(join(dir, name), "utf8")) as { workspaceFolders?: unknown };
            return Array.isArray(lock.workspaceFolders)
              ? lock.workspaceFolders.filter((folder): folder is string => typeof folder === "string" && folder !== "")
              : [];
          } catch {
            return [];
          }
        }),
      );
      return lists.flat();
    } catch {
      return [];
    }
  }

  private async describe(entry: ValidEntry, host: AgentHost): Promise<AgentSession> {
    const transcript = await this.transcript(entry);
    const summary = transcript?.summary;
    const session: AgentSession = {
      id: entry.sessionId,
      agent: this.agent,
      pid: entry.pid,
      cwd: entry.cwd,
      project: basename(entry.cwd) || entry.cwd,
      state: entry.state,
      host,
      startedAt: entry.startedAt,
      updatedAt: Math.max(entry.updatedAt, Math.floor(transcript?.mtimeMs ?? 0)),
    };
    const title = summary?.title ?? summary?.lastPrompt;
    if (title) session.title = title;
    if (entry.state === "waiting" && entry.waitingFor) session.waitingFor = entry.waitingFor;
    if (entry.state === "working") session.activity = activityOf(summary);
    if (summary && summary.steps.length > 0) session.trail = summary.steps.slice(-TRAIL_LIMIT);
    const scheme = entry.entrypoint === "claude-vscode" && host.name ? URL_SCHEMES[host.name] : undefined;
    if (scheme) session.openUrl = `${scheme}://anthropic.claude-code/open?session=${entry.sessionId}`;
    return session;
  }

  /**
   * Журнал читается, только когда файл изменился, и только дописанное: в первый раз — хвост,
   * дальше — новые строки. Файл стал короче — его переписали, хвост читается заново.
   */
  private async transcript(entry: ValidEntry): Promise<CachedTranscript | undefined> {
    const cached = this.transcripts.get(entry.sessionId);
    const path = cached?.path ?? (await this.findTranscript(entry));
    if (!path) return undefined;
    try {
      const info = await stat(path);
      if (cached && cached.size === info.size && cached.mtimeMs === info.mtimeMs) return cached;
      const grown = cached !== undefined && info.size >= cached.offset;
      const { lines, end } = grown ? await readLines(path, cached.offset, info.size) : await readTail(path, info.size);
      // Шаги в сводке — новый массив: прежний уже отдан оболочке в составе сессии.
      const summary = grown ? appendTranscript({ ...cached.summary, steps: [...cached.summary.steps] }, lines) : summarizeTranscript(lines);
      // Заголовок мог остаться выше прочитанного хвоста.
      if (!summary.title && cached?.summary.title) summary.title = cached.summary.title;
      const fresh = { path, size: info.size, mtimeMs: info.mtimeMs, offset: end, summary };
      this.transcripts.set(entry.sessionId, fresh);
      return fresh;
    } catch {
      this.transcripts.delete(entry.sessionId);
      return undefined;
    }
  }

  /** Каталог проекта назван по директории, где сессию начали; она может отличаться от текущей. */
  private async findTranscript(entry: ValidEntry): Promise<string | undefined> {
    const projects = join(this.home, "projects");
    const file = `${entry.sessionId}.jsonl`;
    const expected = join(projects, entry.cwd.replace(/[^a-zA-Z0-9]/g, "-"), file);
    if (await exists(expected)) return expected;
    try {
      for (const name of await readdir(projects)) {
        const candidate = join(projects, name, file);
        if (await exists(candidate)) return candidate;
      }
    } catch {
      // Каталога проектов нет — журналов нет.
    }
    return undefined;
  }
}

interface ValidEntry {
  pid: number;
  sessionId: string;
  cwd: string;
  startedAt: number;
  updatedAt: number;
  entrypoint?: string;
  state: AgentState;
  waitingFor?: string;
}

function validate(raw: RegistryEntry): ValidEntry | undefined {
  if (raw === null || typeof raw !== "object") return undefined;
  const { pid, sessionId, cwd, kind } = raw;
  if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0) return undefined;
  // id попадает в ссылку для редактора — принимаем только то, что выглядит как id.
  if (typeof sessionId !== "string" || !/^[0-9a-zA-Z-]{8,64}$/.test(sessionId)) return undefined;
  if (typeof cwd !== "string" || cwd === "") return undefined;
  // Служебные процессы CLI — не сессии.
  if (kind === "daemon" || kind === "daemon-worker") return undefined;

  const startedAt = typeof raw.startedAt === "number" ? raw.startedAt : 0;
  const entry: ValidEntry = {
    pid,
    sessionId,
    cwd,
    startedAt,
    updatedAt: Math.max(startedAt, numberOr(raw.statusUpdatedAt, 0), numberOr(raw.updatedAt, 0)),
    state: raw.status === "busy" || raw.status === "shell" ? "working" : raw.status === "waiting" ? "waiting" : "idle",
  };
  if (typeof raw.entrypoint === "string") entry.entrypoint = raw.entrypoint;
  if (typeof raw.waitingFor === "string" && raw.waitingFor.trim() !== "") entry.waitingFor = raw.waitingFor.trim();
  return entry;
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function hostFor(entry: ValidEntry, table: ProcessTable, workspaces: string[]): AgentHost {
  let host = hostOf(entry.pid, table);
  // Расширение редактора запускает агента без терминала: окно сессии — окно редактора.
  if (entry.entrypoint === "claude-vscode" && host.kind === "unknown" && host.name) host = { ...host, kind: "ide" };
  if (host.kind === "ide") {
    // Самая глубокая открытая папка, внутри которой работает сессия.
    const cwd = resolve(entry.cwd) + sep;
    const workspace = workspaces
      .filter((folder) => cwd.startsWith(resolve(folder) + sep))
      .sort((a, b) => b.length - a.length)[0];
    if (workspace) host.workspace = workspace;
  }
  return host;
}

function activityOf(summary: TranscriptSummary | undefined): string {
  const last = summary?.steps.at(-1);
  if (last?.kind === "tool") return last.text;
  return last?.kind === "text" ? "пишет ответ…" : "думает…";
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM — процесс есть, но чужой.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

/** Хвост журнала; чтение с середины файла начинается с обрывка строки — он отбрасывается. */
async function readTail(path: string, size: number): Promise<{ lines: string[]; end: number }> {
  const start = Math.max(0, size - TAIL_BYTES);
  const tail = await readLines(path, start, size);
  if (start > 0) tail.lines.shift();
  return tail;
}

/**
 * Полные строки файла между `start` и `size`. `end` — где кончилась последняя полная строка:
 * недописанная агентом строка остаётся на следующее чтение. Строки режутся по байту перевода
 * строки, до декодирования: граница чтения не попадёт в середину символа.
 */
async function readLines(path: string, start: number, size: number): Promise<{ lines: string[]; end: number }> {
  if (size <= start) return { lines: [], end: start };
  const file = await open(path, "r");
  try {
    const buffer = Buffer.alloc(size - start);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, start);
    const data = buffer.subarray(0, bytesRead);
    const last = data.lastIndexOf(0x0a);
    if (last < 0) return { lines: [], end: start };
    return { lines: data.subarray(0, last).toString("utf8").split("\n"), end: start + last + 1 };
  } finally {
    await file.close();
  }
}
