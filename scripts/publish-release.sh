#!/bin/sh
# Выкладывает собранные бандлы релизом в репозиторий релизов: скачивают Luna оттуда,
# там же лежит установщик. Повторный запуск для того же тега заменяет файлы.
#
#   GH_TOKEN=… scripts/publish-release.sh v0.2.0 <каталог с бандлами>
#
# GH_TOKEN — токен с правом Contents на публичный репозиторий (в CI — секрет LUNA_RELEASES_TOKEN).
# RELEASES_REPO — куда выкладывать; по умолчанию stepaKaziatko/luna-releases.
# LUNA_RELEASE_DRAFT=1 — завести черновик: снаружи его не видно, пока не опубликован.
set -eu

tag="$1"
dist="$(cd "$2" && pwd)"
repo="${RELEASES_REPO:-stepaKaziatko/luna-releases}"
root="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ -n "${GH_TOKEN:-}" ] || fail "нет GH_TOKEN: заведите секрет LUNA_RELEASES_TOKEN с правом Contents на $repo"

cd "$dist"
rm -f checksums.txt
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -- * > checksums.txt
else
  shasum -a 256 -- * > checksums.txt
fi

# Заметки — раздел этой версии из CHANGELOG.md, словами пользователя, а не список коммитов.
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
awk -v heading="## ${tag#v}" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$root/CHANGELOG.md" > "$notes"
cat >> "$notes" <<NOTES

Установка на macOS:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | sh
\`\`\`
NOTES

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" ./* --repo "$repo" --clobber
  gh release edit "$tag" --repo "$repo" --notes-file "$notes"
else
  gh release create "$tag" ./* --repo "$repo" --title "Luna $tag" --notes-file "$notes" \
    ${LUNA_RELEASE_DRAFT:+--draft}
fi
echo "✓ $tag → https://github.com/$repo/releases"
