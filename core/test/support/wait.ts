import assert from "node:assert/strict";
import type { ManualExecutor } from "./manual-executor.ts";

/** Ждёт условия, а не фиксированную паузу: на медленном раннере CI запуск задачи может опоздать. */
export async function until(condition: () => boolean, what = "условие"): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!condition()) {
    if (Date.now() > deadline) assert.fail(`не дождались: ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Запуск исполнителя с номером `index` — дожидается его появления. */
export async function nextRun(executor: ManualExecutor, index: number) {
  await until(() => executor.runs.length > index, `запуска исполнителя №${index + 1}`);
  const run = executor.runs[index];
  assert.ok(run);
  return run;
}

/**
 * Пауза только для проверок того, что чего-то НЕ произошло (лишний запуск, лишнее событие).
 * Результат от её длины не зависит: тест проходит и при нулевой.
 */
export const quietPeriod = () => new Promise((resolve) => setTimeout(resolve, 20));
