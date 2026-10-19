#!/bin/sh
# Поднимает версию Luna в project.yml и Info.plist и отдаёт ей раздел «Дальше» из CHANGELOG.md.
# Коммит с новой версией в main — это выпуск: его собирает и публикует workflow Release.
#
#   scripts/bump-version.sh minor     # новая возможность: 0.2.0 → 0.3.0
#   scripts/bump-version.sh patch     # исправление:       0.2.0 → 0.2.1
#   scripts/bump-version.sh 1.0.0     # явный номер
set -eu

cd "$(dirname "$0")/.."

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || fail "нужен один аргумент: major, minor, patch или номер версии"
current=$(scripts/check-version.sh)
IFS=. read -r major minor patch <<VERSION
$current
VERSION
case "$1" in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
  *.*.*) next="$1" ;;
  *) fail "не понимаю «$1»: major, minor, patch или номер вида 1.2.3" ;;
esac
printf '%s\n' "$next" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "версия «$next» не вида 1.2.3"
if grep -qxF "## $next" CHANGELOG.md; then fail "раздел $next в CHANGELOG.md уже есть"; fi

# Заметки версии — раздел «Дальше». Пустой раздел значит, что выпускать пользователю нечего.
notes=$(awk '$0 == "## Дальше" { found = 1; next } found && /^## / { exit } found && NF' CHANGELOG.md)
[ -n "$notes" ] || fail "раздел «Дальше» в CHANGELOG.md пуст: опишите изменение словами пользователя"

# Первая CFBundleShortVersionString в project.yml — таргет Luna; у iPhone-таргетов свои версии.
awk -v ver="$next" '
  !done && /^ *CFBundleShortVersionString: "/ { sub(/"[^"]*"/, "\"" ver "\""); done = 1 }
  { print }
' apps/macos/project.yml > apps/macos/project.yml.bak && mv apps/macos/project.yml.bak apps/macos/project.yml
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" apps/macos/Resources/Info.plist
awk -v next_heading="## $next" '
  $0 == "## Дальше" { print; print ""; print next_heading; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.bak && mv CHANGELOG.md.bak CHANGELOG.md

scripts/check-version.sh >/dev/null
echo "$current → $next"
