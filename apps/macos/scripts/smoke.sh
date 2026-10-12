#!/bin/sh
# Проверяет, что собранный бандл запускается и закрывается: ловит падение на старте в
# упакованном виде (не найден ресурс, сломанная подпись) и зависший процесс. После SIGTERM и
# после SIGKILL за 5 с процесса Luna нет.
#
#   scripts/smoke.sh [путь к Luna.app]     # по умолчанию build/Luna.app
#
# Проверка запускает Luna с домашним каталогом во временной папке: настоящие настройки, сокет
# хуков и журналы в ~/Library она не трогает, поэтому работающей Luna не мешает.
set -eu

app="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/Luna.app}"
log="$(mktemp)"
home="$(mktemp -d)"
pid=""

alive() {
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$state" in "" | Z*) return 1 ;; esac
}

cleanup() {
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  rm -rf "$log" "$home"
}
trap cleanup EXIT

start() {
  HOME="$home" "$app/Contents/MacOS/Luna" >"$log" 2>&1 &
  pid=$!
  sleep 3
  if ! alive "$pid"; then
    echo "✗ Luna завершилась на старте:" >&2
    cat "$log" >&2
    exit 1
  fi
}

expect_gone() {
  n=0
  while [ "$n" -lt 25 ]; do
    if ! alive "$pid"; then
      wait "$pid" 2>/dev/null || true
      echo "✓ $1: Luna завершилась за $((n * 200)) мс"
      pid=""
      return 0
    fi
    sleep 0.2
    n=$((n + 1))
  done
  echo "✗ $1: через 5 с процесс жив:" >&2
  ps -o pid,stat,command -p "$pid" >&2 || true
  exit 1
}

codesign --verify --strict "$app"

start
echo "✓ $app запускается"
kill -TERM "$pid"
expect_gone "SIGTERM"

start
kill -KILL "$pid"
expect_gone "SIGKILL"
