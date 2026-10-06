/**
 * Допустимое значение модели. Оно попадает в argv CLI исполнителя, поэтому первый знак —
 * буква или цифра (не `-флаг`), пробелы и управляющие символы не проходят.
 */
export const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:[\]/-]{0,99}$/;

/** Годится ли значение для argv исполнителя. */
export function isValidModel(model: unknown): model is string {
  return typeof model === "string" && MODEL_PATTERN.test(model);
}
