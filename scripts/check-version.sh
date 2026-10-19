#!/bin/sh
# Версия Luna записана в apps/macos/project.yml (CFBundleShortVersionString таргета Luna) и в
# сгенерированном из него apps/macos/Resources/Info.plist. Скрипт печатает версию, если они
# совпадают и у версии есть раздел в CHANGELOG.md (из него берутся заметки релиза), и падает,
# если что-то разошлось.
#
#   scripts/check-version.sh            # → 0.7.0
set -eu

cd "$(dirname "$0")/.."

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

project=$(sed -n 's/^ *CFBundleShortVersionString: "\(.*\)"$/\1/p' apps/macos/project.yml | head -n 1)
plist=$(awk '/CFBundleShortVersionString/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print }' apps/macos/Resources/Info.plist)

[ -n "$project" ] || fail "не нашли версию в apps/macos/project.yml"
[ "$plist" = "$project" ] || fail "apps/macos/Resources/Info.plist: $plist, а в project.yml — $project (cd apps/macos && xcodegen generate)"
grep -qxF "## $project" CHANGELOG.md || fail "в CHANGELOG.md нет раздела «## $project»"

echo "$project"
