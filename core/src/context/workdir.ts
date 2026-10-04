import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const WORKDIR_TTL_MS = 24 * 60 * 60 * 1000;

export function defaultDataDir(): string {
  if (process.env.LUNA_DATA_DIR) return process.env.LUNA_DATA_DIR;
  if (process.platform === "darwin") return join(homedir(), "Library/Application Support/Luna");
  return join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local/share"), "luna");
}

export async function createTaskWorkdir(tasksDir: string, taskId: string): Promise<string> {
  const dir = join(tasksDir, taskId);
  await mkdir(dir, { recursive: true });
  return dir;
}

/** Удаляет рабочие директории задач старше ttlMs. */
export async function cleanupWorkdirs(tasksDir: string, ttlMs = WORKDIR_TTL_MS, now = Date.now()): Promise<void> {
  let names: string[];
  try {
    names = await readdir(tasksDir);
  } catch {
    return;
  }
  await Promise.all(
    names.map(async (name) => {
      const dir = join(tasksDir, name);
      try {
        const info = await stat(dir);
        if (info.isDirectory() && now - info.mtimeMs > ttlMs) await rm(dir, { recursive: true, force: true });
      } catch {
        // Директорию мог удалить параллельный процесс — это не ошибка.
      }
    }),
  );
}
