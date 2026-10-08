import type { PermissionLevel } from "../rpc/protocol.gen.ts";

// Все значения `PermissionLevel` протокола: таблица не соберётся, если в схеме появится уровень,
// которого здесь нет. Что уровень значит, знает исполнитель; ядро только проверяет форму.
const LEVELS: Readonly<Record<PermissionLevel, true>> = { manual: true, edit_automatically: true };

/** Значение из перечисления `PermissionLevel`. */
export function isPermissionLevel(value: unknown): value is PermissionLevel {
  return typeof value === "string" && Object.hasOwn(LEVELS, value);
}
