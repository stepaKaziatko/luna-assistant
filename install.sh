#!/bin/sh
#
# Установка Luna на macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/stepaKaziatko/luna-assistant/main/install.sh | sh
#
# Качает последний релиз, сверяет контрольную сумму и кладёт Luna.app в «Программы».
# Тем же скриптом Luna обновляется.
#
#   LUNA_VERSION=v1.0.0          конкретный релиз вместо последнего
#   LUNA_INSTALL_DIR=~/Apps      куда класть; по умолчанию /Applications,
#                                если он доступен на запись, иначе ~/Applications
set -eu

repo="stepaKaziatko/luna-assistant"
# Релизы до v1.0.0 включительно выкладывались в отдельный репозиторий — теперь это архив.
# Их файлы берём оттуда: в этом репозитории у старых релизов файлов нет.
archive_repo="stepaKaziatko/luna-releases"
version="${LUNA_VERSION:-}"

say() { printf '%s\n' "$*" >&2; }
die() { say "✗ $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "нужен $1"; }

# Минимум macOS у Luna — одна цифра (сейчас macOS 15): проверка установки в Release
# сверяет её с LSMinimumSystemVersion собранного бандла.
min_macos=15

[ "$(uname -s)" = Darwin ] || die "приложение Luna есть только под macOS"
macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge "$min_macos" ] || die "нужна macOS $min_macos или новее, здесь $macos"
need curl
need ditto
need shasum

# Последний релиз — по перенаправлению с /releases/latest: так не нужен ни
# jq для разбора ответа API, ни его лимит на запросы без токена.
if [ -n "$version" ]; then
  tag="$version"
else
  latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$repo/releases/latest") || die "не дозвонились до GitHub"
  tag="${latest##*/tag/}"
  case "$tag" in
    v*) ;;
    *) die "не разобрали последний релиз из $latest" ;;
  esac
fi

case "$tag" in
  v0.* | v1.0.0) from="$archive_repo" ;;
  *) from="$repo" ;;
esac

archive="Luna-${tag#v}-macos-universal.zip"
# LUNA_DOWNLOAD_BASE — откуда брать файлы релиза; нужен только для проверки самого скрипта.
base="${LUNA_DOWNLOAD_BASE:-https://github.com/$from/releases/download/$tag}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "▸ качаем $archive"
curl -fsSL -o "$tmp/$archive" "$base/$archive" || die "в релизе $tag нет $archive"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" || die "в релизе $tag нет checksums.txt"

want=$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/checksums.txt")
have=$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')
[ -n "$want" ] && [ "$want" = "$have" ] || die "контрольная сумма $archive не сошлась"

ditto -x -k "$tmp/$archive" "$tmp/unpacked"
[ -d "$tmp/unpacked/Luna.app" ] || die "в $archive нет Luna.app"

dir="${LUNA_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
  if [ -w /Applications ]; then dir=/Applications; else dir="$HOME/Applications"; fi
fi
mkdir -p "$dir"

# Запущенная Luna держит старый бандл: закрываем её, прежде чем менять.
was_running=false
if [ -d "$dir/Luna.app" ] && pgrep -x Luna >/dev/null 2>&1; then
  was_running=true
  pkill -x Luna || true
  sleep 1
fi
rm -rf "$dir/Luna.app"
mv "$tmp/unpacked/Luna.app" "$dir/Luna.app"
# Сборка не нотаризована Apple: без этого Gatekeeper не даст её открыть,
# если архив или скрипт были скачаны браузером.
xattr -dr com.apple.quarantine "$dir/Luna.app" 2>/dev/null || true

say "✓ Luna $tag → $dir/Luna.app"
if $was_running; then
  say "  прежняя версия была запущена и закрыта; macOS может заново спросить разрешения"
fi
say "  запустить: open \"$dir/Luna.app\" — остров появится у верхнего края экрана, чат открывается по ⌃⌥Space"
