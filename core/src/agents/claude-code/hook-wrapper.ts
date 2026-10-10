import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Стабильная точка входа хука `PermissionRequest` чужих сессий. Путь к `bridge.js` в бандле меняется с
// обновлением и переносом Luna.app, а сокет ядра называется случайно на каждый запуск. Поэтому ядро при
// старте пишет в свой каталог данных небольшой `sh`-файл с подставленными путями: в настройки Claude
// Code пользователь вписывает путь к нему один раз, и он не меняется между версиями. Это файл Luna в её
// каталоге; настройки и файлы Claude Code ядро не трогает.

/** Путь обёртки относительно каталога данных. */
export const HOOK_WRAPPER_NAME = "bin/luna-agent-hook";

/** Абсолютный путь обёртки. */
export const hookWrapperPath = (dataDir: string): string => join(dataDir, HOOK_WRAPPER_NAME);

const quote = (value: string): string => `'${value.replace(/'/g, `'\\''`)}'`;

/** Текст обёртки: нет живого сокета ядра — тихий выход без запуска `node`; есть — мост `agent-hook`. */
export function hookWrapperScript(dataDir: string, node: string, bridge: string): string {
  return [
    "#!/bin/sh",
    "# Создан ядром Luna при каждом запуске; пути подставляются заново, править файл не нужно.",
    "# Хук PermissionRequest: Luna закрыта — выходим сразу, и Claude Code спрашивает в терминале.",
    `dir=${quote(dataDir)}`,
    'for sock in "$dir"/approvals-*.sock; do',
    `  [ -S "$sock" ] && exec ${quote(node)} ${quote(bridge)} agent-hook "$dir"`,
    "done",
    "exit 0",
    "",
  ].join("\n");
}

/** Пишет обёртку (временный файл и переименование: хук не прочтёт половину файла). Возвращает её путь. */
export async function writeHookWrapper(dataDir: string, node: string, bridge: string): Promise<string> {
  const path = hookWrapperPath(dataDir);
  await mkdir(join(dataDir, "bin"), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, hookWrapperScript(dataDir, node, bridge), { mode: 0o755 });
  await chmod(temporary, 0o755);
  await rename(temporary, path);
  return path;
}
