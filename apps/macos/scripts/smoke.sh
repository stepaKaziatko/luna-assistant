#!/bin/sh
# Проверяет, что собранный бандл запускается и закрывается: ловит падение на старте в
# упакованном виде (не найден ресурс, сломанная подпись) и зависший процесс. После SIGTERM и
# после SIGKILL за 5 с процесса Luna нет.
#
#   scripts/smoke.sh [путь к Luna.app]     # по умолчанию build/Luna.app
#
# Проверка не трогает установленную Luna и проходит, пока та запущена:
# - подпись исходного бандла проверяет codesign --verify --strict, а запускается его временная
#   копия с Bundle ID dev.luna.Luna.smoke, переподписанная ad-hoc с теми же энтайтлментами:
#   у копии свой домен настроек в ~/Library/Preferences (UserDefaults не переадресовать
#   переменной окружения), он удаляется в конце;
# - копия работает с домом во временной папке /tmp/luna-smoke.XXXXXX: CFFIXED_USER_HOME
#   переадресует Application Support (сокет хуков, luna-hook), журналы и Keychain, а HOME —
#   то, что берётся из окружения. Одного HOME мало: Foundation берёт дом не из него. Папка
#   короткая, чтобы путь сокета уложился в 103 байта sun_path;
# - скрипт сам проверяет изоляцию: сокет копии появился во временной папке, а настоящие
#   luna.sock, luna-hook и luna-hook.py не изменились (inode и время изменения).
# Видимым остаётся остров копии: он появляется на ~3 с при каждом из двух стартов.
set -eu

app="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/Luna.app}"
smoke_id=dev.luna.Luna.smoke
real_dir="$HOME/Library/Application Support/Luna"
tmp="$(mktemp -d /tmp/luna-smoke.XXXXXX)"
home="$tmp/home"
copy="$tmp/Luna.app"
log="$tmp/luna.log"
smoke_sock="$home/Library/Application Support/Luna/luna.sock"
pid=""

alive() {
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$state" in "" | Z*) return 1 ;; esac
}

# Домен настроек копии: defaults delete оставляет пустой plist — его тоже убрать.
forget_defaults() {
  defaults delete "$smoke_id" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$smoke_id.plist"
}

cleanup() {
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  rm -rf "$tmp"
  # Кэш Metal копии система кладёт мимо дома — в каталог кэшей пользователя по Bundle ID.
  cache="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
  if [ -n "$cache" ]; then rm -rf "$cache$smoke_id"; fi
  forget_defaults
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "✗ $*" >&2
  exit 1
}

real_files="luna.sock luna-hook luna-hook.py"

# inode и время изменения настоящего файла Luna; «нет», если файла нет.
stamp() {
  stat -f '%i %m' "$real_dir/$1" 2>/dev/null || echo нет
}

snapshot() {
  for f in $real_files; do printf '%s=%s\n' "$f" "$(stamp "$f")"; done
}

check_real() {
  touched=""
  for f in $real_files; do
    was="$(printf '%s\n' "$before" | sed -n "s/^$f=//p")"
    now="$(stamp "$f")"
    if [ "$was" != "$now" ]; then
      touched="$touched $f"
      echo "  $real_dir/$f: было «${was}», стало «${now}»" >&2
    fi
  done
  [ -z "$touched" ] || fail "изоляция не сработала ($1), проверка задела настоящие файлы Luna:$touched"
}

start() {
  CFFIXED_USER_HOME="$home" HOME="$home" "$copy/Contents/MacOS/Luna" >"$log" 2>&1 &
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

# Копия с другим Bundle ID. Правка Info.plist ломает подпись бандла — переподписать: вложенный
# код раньше бандла, как в bundle.sh.
mkdir -p "$home"
ditto --noextattr --noqtn "$app" "$copy"
plutil -replace CFBundleIdentifier -string "$smoke_id" "$copy/Contents/Info.plist"
find "$copy/Contents" -name '*.dylib' -print0 | xargs -0 -r codesign --force --sign -
codesign --force --sign - --options runtime --preserve-metadata=entitlements "$copy"
forget_defaults

before="$(snapshot)"

start
check_real "во время запуска"
[ -S "$smoke_sock" ] || fail "сокет проверки не появился в $smoke_sock: переадресация дома не сработала"
echo "✓ изоляция: сокет проверки в $tmp, настоящие luna.sock, luna-hook, luna-hook.py не тронуты"
echo "✓ $app запускается"
kill -TERM "$pid"
expect_gone "SIGTERM"

start
kill -KILL "$pid"
expect_gone "SIGKILL"
check_real "после запусков"
