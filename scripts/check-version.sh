#!/bin/sh
# Версия Luna записана в трёх местах: core/package.json, константа VERSION ядра и Info.plist
# приложения. Скрипт печатает версию, если они совпадают, и падает, если разошлись.
#
#   scripts/check-version.sh            # → 0.2.0
#   scripts/check-version.sh v0.2.0     # заодно сверяет с тегом релиза
set -eu

cd "$(dirname "$0")/.."

package=$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' core/package.json)
core=$(sed -n 's/^const VERSION = "\(.*\)";$/\1/p' core/src/main.ts)
plist=$(awk '/CFBundleShortVersionString/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print }' apps/macos/Bundle/Info.plist)

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ -n "$package" ] || fail "не нашли версию в core/package.json"
[ "$core" = "$package" ] || fail "core/src/main.ts: VERSION = \"$core\", а в core/package.json — $package"
[ "$plist" = "$package" ] || fail "apps/macos/Bundle/Info.plist: $plist, а в core/package.json — $package"
if [ $# -gt 0 ] && [ "$1" != "v$package" ]; then
  fail "тег $1 не совпадает с версией в репозитории (v$package)"
fi

echo "$package"
