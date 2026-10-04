#!/bin/sh
# Проверяет, что собранный бандл запускается: приложение живо через несколько секунд
# и подняло ядро. Ловит то, чего не видят тесты, — падение на старте в упакованном виде
# (не найден ресурсный бандл зависимости, ядро, Node).
#
#   scripts/smoke.sh [путь к Luna.app]     # по умолчанию build/Luna.app
set -eu

app="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/Luna.app}"
log="$(mktemp)"
data_dir="$(mktemp -d)"

codesign --verify --strict "$app"

# Свой каталог данных: проверка не трогает задачи настоящей Luna.
LUNA_DATA_DIR="$data_dir" "$app/Contents/MacOS/Luna" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; rm -rf "$log" "$data_dir"' EXIT

sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
  echo "✗ Luna завершилась на старте:" >&2
  cat "$log" >&2
  exit 1
fi
if ! pgrep -P "$pid" -f 'core/main.js' >/dev/null; then
  echo "✗ Luna запустилась, но ядро не поднято:" >&2
  cat "$log" >&2
  exit 1
fi
echo "✓ $app запускается, ядро поднято"
