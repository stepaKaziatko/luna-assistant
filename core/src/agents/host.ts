import { execFile } from "node:child_process";
import { basename } from "node:path";
import type { AgentHost } from "../rpc/protocol.gen.ts";

// Чьё окно показывает сессию: по цепочке родительских процессов ищем приложение-бандл.

export interface ProcessRow {
  pid: number;
  ppid: number;
  /** Управляющий терминал: /dev/ttys003. */
  tty?: string;
  /** Полный путь исполняемого файла. */
  command: string;
}

export type ProcessTable = Map<number, ProcessRow>;

/** Редакторы, которые открывают папку проекта в своём окне. */
const IDE_NAMES =
  /^(Visual Studio Code( - Insiders)?|VSCodium|Cursor|Windsurf|Zed( Preview)?|Xcode|Android Studio|Fleet|IntelliJ IDEA.*|PyCharm.*|WebStorm|GoLand|RubyMine|CLion|Rider|PhpStorm|RustRover)$/;

/** Глубже хозяин не ищется: цепочка «агент → оболочка → терминал» короткая. */
const MAX_DEPTH = 12;

/** Разбирает вывод `ps -axo pid=,ppid=,tty=,comm=`. */
export function parseProcessTable(output: string): ProcessTable {
  const table: ProcessTable = new Map();
  for (const line of output.split("\n")) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+)$/.exec(line);
    if (!match) continue;
    const row: ProcessRow = { pid: Number(match[1]), ppid: Number(match[2]), command: match[4] ?? "" };
    if (match[3] && match[3] !== "??") row.tty = `/dev/${match[3]}`;
    table.set(row.pid, row);
  }
  return table;
}

export function readProcessTable(): Promise<ProcessTable> {
  return new Promise((resolve) => {
    execFile("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="], { maxBuffer: 8 * 1024 * 1024 }, (error, stdout) => {
      resolve(error ? new Map() : parseProcessTable(stdout));
    });
  });
}

/** Приложение, внутри которого работает процесс `pid`, и терминал процесса. */
export function hostOf(pid: number, table: ProcessTable): AgentHost {
  const tty = table.get(pid)?.tty;
  let current = table.get(pid);
  for (let depth = 0; current && depth < MAX_DEPTH; depth += 1) {
    const appPath = bundleOf(current.command);
    if (appPath) {
      const name = basename(appPath, ".app");
      const host: AgentHost = { kind: IDE_NAMES.test(name) ? "ide" : tty ? "terminal" : "unknown", name, appPath };
      if (tty) host.tty = tty;
      return host;
    }
    current = table.get(current.ppid);
  }
  return tty ? { kind: "terminal", tty } : { kind: "unknown" };
}

/** Внешний бандл: у «…/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/…» это сам редактор. */
function bundleOf(command: string): string | undefined {
  const end = command.indexOf(".app/Contents/");
  return end < 0 ? undefined : command.slice(0, end + ".app".length);
}
