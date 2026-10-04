#!/bin/sh
# Версия Luna записана в трёх местах: core/package.json, константа VERSION ядра и Info.plist
# приложения. Скрипт печатает версию, если они совпадают и у версии есть раздел в CHANGELOG.md
# (из него берутся заметки релиза), и падает, если что-то разошлось.
#
#   scripts/check-version.sh            # → 0.2.0
set -eu

cd "$(dirname "$0")/.."

package=$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' core/package.json)
core=$(sed -n 's/^const VERSION = "\(.*\)";$/\1/p' core/src/main.ts)
plist=$(awk '/CFBundleShortVersionString/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print }' apps/macos/Bundle/Info.plist)

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ -n "$package" ] || fail "не нашли версию в core/package.json"
[ "$core" = "$package" ] || fail "core/src/main.ts: VERSION = \"$core\", а в core/package.json — $package"
[ "$plist" = "$package" ] || fail "apps/macos/Bundle/Info.plist: $plist, а в core/package.json — $package"
grep -qxF "## $package" CHANGELOG.md || fail "в CHANGELOG.md нет раздела «## $package»"

echo "$package"
