#!/bin/sh
# Выкладывает собранный архив черновиком релиза в этот репозиторий. Черновик снаружи не виден
# и тега не ставит: тег появляется, когда Release публикует черновик после проверки установки.
# Повторный запуск для того же тега заменяет файлы, заметки и коммит черновика.
#
#   GH_TOKEN=… GITHUB_SHA=<коммит> scripts/publish-release.sh v1.1.0 <каталог с архивом>
#
# GH_TOKEN — токен с правом Contents на этот репозиторий (в CI — github.token).
# GITHUB_SHA — коммит, на который встанет тег при публикации.
# checksums.txt в каталоге — суммы, с которыми архив прошёл проверку установки; его нет —
# скрипт посчитает сам. Перед выкладкой суммы сверяются.
set -eu

tag="$1"
dist="$(cd "$2" && pwd)"
repo="stepaKaziatko/luna-assistant"
root="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ -n "${GH_TOKEN:-}" ] || fail "нет GH_TOKEN с правом Contents на $repo"
target="${GITHUB_SHA:-}"
[ -n "$target" ] || fail "нет GITHUB_SHA: на какой коммит ставить тег"

cd "$dist"
ls ./*.zip >/dev/null 2>&1 || fail "в $dist нет архива *.zip"
if [ ! -f checksums.txt ]; then
  shasum -a 256 -- *.zip > checksums.txt
fi
shasum -a 256 -c checksums.txt >/dev/null || fail "checksums.txt не сходится с архивом в $dist"

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
  gh release upload "$tag" ./*.zip checksums.txt --repo "$repo" --clobber
  gh release edit "$tag" --repo "$repo" --target "$target" --notes-file "$notes"
else
  gh release create "$tag" ./*.zip checksums.txt --repo "$repo" --draft --target "$target" \
    --title "Luna $tag" --notes-file "$notes"
fi
echo "✓ $tag: черновик → https://github.com/$repo/releases"
