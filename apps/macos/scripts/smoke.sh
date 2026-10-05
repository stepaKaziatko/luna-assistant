#!/bin/sh
# Проверяет, что собранный бандл запускается и закрывается. Запуск: приложение живо и подняло ядро —
# ловит то, чего не видят тесты, то есть падение на старте в упакованном виде (не найден ресурсный
# бандл зависимости, ядро, Node). Выход: после SIGTERM и SIGKILL за 5 с нет ни Luna, ни её ядра,
# а в debug-бандле то же после команды `quit` («Выйти из Luna»).
#
#   scripts/smoke.sh [--debug] [путь к Luna.app]     # по умолчанию build/Luna.app
#
# --debug — бандл собран `bundle.sh debug`: у него есть команда `quit`. У релизного бандла её нет,
# и без флага этот сценарий пропускается.
#
# Проверка смотрит только на процессы, которые сама запустила (по pid): другая Luna на этой машине,
# в том числе с таким же ядром, ей не мешает и не гасится.
set -eu

debug=0
app=""
for arg in "$@"; do
  case "$arg" in
    --debug) debug=1 ;;
    *) app="$arg" ;;
  esac
done
app="${app:-$(cd "$(dirname "$0")/.." && pwd)/build/Luna.app}"
command_script="$(cd "$(dirname "$0")" && pwd)/debug-command.sh"
log="$(mktemp)"
data_dir=""
pid=""
core=""

# Процесс жив: не завершён и не зомби (до wait завершённый потомок остаётся зомби, и kill -0 его видит).
alive() {
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$state" in "" | Z*) return 1 ;; esac
}

cleanup() {
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  [ -n "$core" ] && kill -KILL "$core" 2>/dev/null || true
  rm -rf "$log" "$data_dir"
}
trap cleanup EXIT

# Запускает Luna с чистым каталогом данных (проверка не трогает задачи настоящей) и ждёт ядро до 10 с.
start() {
  rm -rf "$data_dir"
  data_dir="$(mktemp -d)"
  LUNA_DATA_DIR="$data_dir" "$app/Contents/MacOS/Luna" >"$log" 2>&1 &
  pid=$!
  core=""
  n=0
  while [ "$n" -lt 40 ]; do
    core="$(pgrep -P "$pid" -f 'core/main.js' | head -n 1 || true)"
    [ -n "$core" ] && break
    alive "$pid" || break
    sleep 0.25
    n=$((n + 1))
  done
  # Ядро успевает подняться за долю секунды; пауза — чтобы поймать падение сразу после старта.
  sleep 1
  if ! alive "$pid"; then
    echo "✗ Luna завершилась на старте:" >&2
    cat "$log" >&2
    exit 1
  fi
  if [ -z "$core" ]; then
    echo "✗ Luna запустилась, но ядро не поднято:" >&2
    cat "$log" >&2
    exit 1
  fi
}

# Ждёт до 5 с, пока не исчезнут Luna и её ядро; иначе — ошибка с оставшимися процессами.
expect_gone() {
  n=0
  while [ "$n" -lt 25 ]; do
    if ! alive "$pid" && ! alive "$core"; then
      wait "$pid" 2>/dev/null || true
      echo "✓ $1: за $((n * 200)) мс нет ни Luna, ни ядра"
      return 0
    fi
    sleep 0.2
    n=$((n + 1))
  done
  echo "✗ $1: через 5 с остались процессы:" >&2
  ps -o pid,ppid,stat,command -p "$pid,$core" >&2 || true
  exit 1
}

codesign --verify --strict "$app"

start
echo "✓ $app запускается, ядро поднято"

kill -TERM "$pid"
expect_gone "SIGTERM"

# Убитая без предупреждения оболочка не успевает ничего закрыть: ядро и исполнитель уходят сами, по EOF в stdin ядра.
start
kill -KILL "$pid"
expect_gone "SIGKILL"

if [ "$debug" = 1 ]; then
  start
  "$command_script" "@$pid:quit"
  expect_gone "«Выйти из Luna»"
else
  echo "– «Выйти из Luna»: пропущено, у релизного бандла нет debug-команд (--debug)"
fi
