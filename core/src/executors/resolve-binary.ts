import { access, constants } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

// GUI-приложения на macOS стартуют с урезанным PATH, поэтому после PATH
// проверяем типичные места установки CLI.
const FALLBACK_DIRS = [join(homedir(), ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"];

export async function resolveBinary(name: string, override?: string): Promise<string | undefined> {
  if (override) return (await isExecutable(override)) ? override : undefined;

  const dirs = [...(process.env.PATH ?? "").split(delimiter).filter(Boolean), ...FALLBACK_DIRS];
  for (const dir of dirs) {
    const candidate = join(dir, name);
    if (await isExecutable(candidate)) return candidate;
  }
  return undefined;
}

async function isExecutable(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}
