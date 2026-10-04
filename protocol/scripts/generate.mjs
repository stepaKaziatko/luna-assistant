// Генерирует типы протокола из JSON Schema в оба потребителя: core (TS) и macOS shell (Swift).
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const schema = resolve(root, "protocol/schema/protocol.schema.json");
const banner = "// СГЕНЕРИРОВАНО из protocol/schema/protocol.schema.json — не редактировать.\n// Обновить: npm run generate\n\n";

const targets = [
  {
    out: resolve(root, "core/src/rpc/protocol.gen.ts"),
    args: ["--lang", "typescript", "--acronym-style", "camel", "--just-types", "--prefer-unions", "--no-date-times"],
  },
  {
    out: resolve(root, "apps/macos/Sources/Luna/Protocol/Protocol.gen.swift"),
    args: [
      "--lang", "swift",
      "--acronym-style", "camel",
      "--struct-or-class", "struct",
      "--no-initializers",
      "--protocol", "equatable",
      "--sendable",
      "--access-level", "internal",
      "--no-date-times",
    ],
  },
];

// quicktype добавляет шапку с примерами и повторяющиеся пояснения про Hashable — убираем их.
function stripBoilerplate(source) {
  return source
    .replace(/^\/\/ This file was generated[\s\S]*?(?=^import )/m, "")
    .replace(/^\/\/\n\/\/ Hashable or Equatable:\n(?:\/\/ .*\n)+\n/gm, "");
}

for (const { out, args } of targets) {
  execFileSync(
    "npx",
    ["quicktype", "--src-lang", "schema", "--src", `${schema}#/definitions/`, "--out", out, ...args],
    { cwd: resolve(root, "protocol"), stdio: "inherit" },
  );
  writeFileSync(out, banner + stripBoilerplate(readFileSync(out, "utf8")));
  console.log(`generated ${out}`);
}
