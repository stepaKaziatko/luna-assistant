import { existsSync, mkdirSync, renameSync } from "node:fs";
import { join } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import type { TaskInfo, TaskStatus } from "../rpc/protocol.gen.ts";

/** Сколько задач хранится; более старые удаляются при старте ядра. */
export const HISTORY_LIMIT = 1000;

/** Текст ошибки задачи, которую не дал завершить выход из Luna или падение ядра. */
export const INTERRUPTED_MESSAGE = "Luna была закрыта до завершения задачи";

/** Задача из истории вместе с внутренними полями, которые в протокол не выходят. */
export interface StoredTask {
  task: TaskInfo;
  /** Рабочая директория, в которой запускался исполнитель. */
  workdir?: string;
}

/** История задач на диске. Методы бросают исключения — их перехватывает вызывающий. */
export interface TaskHistory {
  /** Записывает снимок задачи (без `progress`) поверх прежнего. */
  save(task: TaskInfo, workdir?: string): void;
  /** Последние задачи по времени создания, новые первыми. */
  recent(limit: number): StoredTask[];
  close(): void;
}

export interface OpenHistoryOptions {
  /** Время старта: им помечаются задачи, прерванные прошлым запуском. */
  now?: number;
  limit?: number;
  log?: (message: string) => void;
}

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS tasks (
    id          TEXT PRIMARY KEY,
    prompt      TEXT NOT NULL,
    context     TEXT,
    status      TEXT NOT NULL,
    executor    TEXT NOT NULL,
    result      TEXT,
    error       TEXT,
    session_id  TEXT,
    created_at  INTEGER NOT NULL,
    finished_at INTEGER,
    workdir     TEXT
  );
  CREATE INDEX IF NOT EXISTS tasks_created_at ON tasks (created_at);
  PRAGMA user_version = 1;
`;

/**
 * Открывает `history.db` в каталоге данных и приводит её в порядок: задачи, оставшиеся
 * незавершёнными, становятся ошибкой, лишние старые удаляются. Повреждённый файл
 * переименовывается и создаётся новый. Без хранилища (нет `node:sqlite`, файл не создаётся)
 * возвращает undefined — Luna работает без истории.
 */
export async function openHistory(dataDir: string, options: OpenHistoryOptions = {}): Promise<TaskHistory | undefined> {
  const log = options.log ?? ((message: string) => process.stderr.write(`[core] ${message}\n`));
  let sqlite: typeof import("node:sqlite");
  try {
    // Динамически: на Node без node:sqlite ядро должно стартовать, пусть и без истории.
    sqlite = await import("node:sqlite");
  } catch (error) {
    log(`история задач недоступна: ${describe(error)}`);
    return undefined;
  }

  const path = join(dataDir, "history.db");
  try {
    mkdirSync(dataDir, { recursive: true });
  } catch (error) {
    log(`история задач недоступна: ${describe(error)}`);
    return undefined;
  }

  const prepare = (): SqliteHistory => {
    const db = new sqlite.DatabaseSync(path);
    try {
      return new SqliteHistory(db, options.now ?? Date.now(), options.limit ?? HISTORY_LIMIT);
    } catch (error) {
      db.close();
      throw error;
    }
  };

  try {
    return prepare();
  } catch (error) {
    log(`history.db не открывается: ${describe(error)}`);
    // Файл занят другим процессом — он цел, откладывать его нельзя.
    if (isBusy(error)) return undefined;
  }
  try {
    const broken = join(dataDir, `history.broken-${Date.now()}.db`);
    renameSync(path, broken);
    if (existsSync(`${path}-journal`)) renameSync(`${path}-journal`, `${broken}-journal`);
    log(`history.db переименован в ${broken}, создаётся новый`);
    return prepare();
  } catch (error) {
    log(`история задач недоступна: ${describe(error)}`);
    return undefined;
  }
}

class SqliteHistory implements TaskHistory {
  private readonly db: DatabaseSync;
  private readonly upsert;
  private readonly select;

  /** Бросает, если файл — не база SQLite: `DatabaseSync` узнаёт это только на первом запросе. */
  constructor(db: DatabaseSync, now: number, limit: number) {
    this.db = db;
    db.exec("PRAGMA busy_timeout = 2000;");
    db.exec(SCHEMA);
    this.upsert = db.prepare(`
      INSERT INTO tasks (id, prompt, context, status, executor, result, error, session_id, created_at, finished_at, workdir)
      VALUES ($id, $prompt, $context, $status, $executor, $result, $error, $sessionId, $createdAt, $finishedAt, $workdir)
      ON CONFLICT (id) DO UPDATE SET
        prompt = excluded.prompt, context = excluded.context, status = excluded.status,
        executor = excluded.executor, result = excluded.result, error = excluded.error,
        session_id = excluded.session_id, created_at = excluded.created_at,
        finished_at = excluded.finished_at, workdir = COALESCE(excluded.workdir, tasks.workdir)
    `);
    this.select = db.prepare("SELECT * FROM tasks ORDER BY created_at DESC, rowid DESC LIMIT ?");

    db.prepare(`
      UPDATE tasks SET status = 'failed', error = ?, finished_at = ?
      WHERE status IN ('queued', 'running')
    `).run(JSON.stringify({ kind: "unknown", message: INTERRUPTED_MESSAGE }), now);
    db.prepare(`
      DELETE FROM tasks WHERE id NOT IN (SELECT id FROM tasks ORDER BY created_at DESC, rowid DESC LIMIT ?)
    `).run(limit);
  }

  save(task: TaskInfo, workdir?: string): void {
    this.upsert.run({
      $id: task.id,
      $prompt: task.prompt,
      $context: task.context ? JSON.stringify(task.context) : null,
      $status: task.status,
      $executor: task.executor,
      $result: task.result ?? null,
      $error: task.error ? JSON.stringify(task.error) : null,
      $sessionId: task.sessionId ?? null,
      $createdAt: task.createdAt,
      $finishedAt: task.finishedAt ?? null,
      $workdir: workdir ?? null,
    });
  }

  recent(limit: number): StoredTask[] {
    return this.select.all(limit).map((row) => toStored(row as unknown as Row));
  }

  close(): void {
    this.db.close();
  }
}

interface Row {
  id: string;
  prompt: string;
  context: string | null;
  status: TaskStatus;
  executor: TaskInfo["executor"];
  result: string | null;
  error: string | null;
  session_id: string | null;
  created_at: number;
  finished_at: number | null;
  workdir: string | null;
}

function toStored(row: Row): StoredTask {
  const task: TaskInfo = {
    id: row.id,
    prompt: row.prompt,
    status: row.status,
    executor: row.executor,
    createdAt: row.created_at,
  };
  if (row.context !== null) task.context = JSON.parse(row.context) as TaskInfo["context"];
  if (row.result !== null) task.result = row.result;
  if (row.error !== null) task.error = JSON.parse(row.error) as TaskInfo["error"];
  if (row.session_id !== null) task.sessionId = row.session_id;
  if (row.finished_at !== null) task.finishedAt = row.finished_at;
  return row.workdir === null ? { task } : { task, workdir: row.workdir };
}

/** SQLITE_BUSY и SQLITE_LOCKED, в том числе расширенные коды. */
function isBusy(error: unknown): boolean {
  const code = (error as { errcode?: unknown } | null)?.errcode;
  return typeof code === "number" && ((code & 0xff) === 5 || (code & 0xff) === 6);
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
