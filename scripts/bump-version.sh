#!/bin/sh
# Поднимает версию Luna во всех местах, где она записана, и отдаёт ей раздел «Дальше»
# из CHANGELOG.md. Коммит с новой версией в main — это выпуск: его собирает и публикует
# workflow Release.
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

npm version "$next" --workspace core --no-git-tag-version >/dev/null
sed -i.bak "s/^const VERSION = \".*\";$/const VERSION = \"$next\";/" core/src/main.ts
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" apps/macos/Bundle/Info.plist 2>/dev/null ||
  sed -i.bak "/CFBundleShortVersionString/{n;s|<string>.*</string>|<string>$next</string>|;}" apps/macos/Bundle/Info.plist
awk -v next_heading="## $next" '
  $0 == "## Дальше" { print; print ""; print next_heading; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.bak && mv CHANGELOG.md.bak CHANGELOG.md
rm -f core/src/main.ts.bak apps/macos/Bundle/Info.plist.bak

scripts/check-version.sh >/dev/null
echo "$current → $next"
