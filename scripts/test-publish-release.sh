#!/usr/bin/env bash
# Проверяет scripts/publish-release.sh без GitHub: gh подменяется заглушкой, которая пишет свои
# вызовы в журнал. Новый тег — черновик в luna-assistant с коммитом, архивом и суммами;
# релиз уже есть — файлы дозаливаются с заменой, заметки и коммит правятся, второго create нет.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-publish.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

failures=0
ok() { printf '✓ %s\n' "$1"; }
bad() { printf '✗ %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

repo="stepaKaziatko/luna-assistant"
sha="0123456789abcdef0123456789abcdef01234567"
# Тег с готовым разделом в CHANGELOG.md: его заметки должны попасть в релиз.
tag="v1.0.0"
changelog_line=$(awk '$0 == "## 1.0.0" { getline; while ($0 == "") getline; print; exit }' CHANGELOG.md)

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
prev=""
for arg; do
  [ "$prev" = "--notes-file" ] && cp "$arg" "$GH_NOTES"
  prev="$arg"
done
case "$1 $2" in
  "release view") [ "${GH_RELEASE_EXISTS:-0}" = 1 ] ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/gh"

new_dist() {
  local dist="$TEST_DIR/dist-$1"
  mkdir -p "$dist"
  printf 'архив %s\n' "$1" > "$dist/Luna-1.0.0-macos-universal.zip"
  printf '%s' "$dist"
}

run_publish() {
  local exists="$1" dist="$2"
  : > "$TEST_DIR/gh.log"
  rm -f "$TEST_DIR/notes.md"
  env PATH="$TEST_DIR/bin:$PATH" GH_LOG="$TEST_DIR/gh.log" GH_NOTES="$TEST_DIR/notes.md" \
    GH_RELEASE_EXISTS="$exists" GH_TOKEN=test GITHUB_SHA="$sha" \
    sh scripts/publish-release.sh "$tag" "$dist"
}

# 1. Нового тега нет — черновик.
dist=$(new_dist new)
if run_publish 0 "$dist" > "$TEST_DIR/out" 2>&1; then ok "новый тег: скрипт прошёл"; else bad "новый тег: скрипт упал: $(cat "$TEST_DIR/out")"; fi
create=$(grep '^release create ' "$TEST_DIR/gh.log" || true)
check "новый тег: один create" "[ \$(grep -c '^release create ' '$TEST_DIR/gh.log') -eq 1 ]"
check "create — в $repo" "[[ \"\$create\" == *'--repo $repo'* ]]"
check "create — черновиком" "[[ \"\$create\" == *' --draft'* ]]"
check "create — с --target $sha" "[[ \"\$create\" == *\"--target $sha\"* ]]"
check "create — архив и checksums.txt" "[[ \"\$create\" == *'Luna-1.0.0-macos-universal.zip'* ]] && [[ \"\$create\" == *' checksums.txt'* ]]"
check "нет --generate-notes" "! grep -q -- '--generate-notes' '$TEST_DIR/gh.log'"
check "checksums.txt проходит shasum -c" "(cd '$dist' && shasum -a 256 -c checksums.txt >/dev/null)"
check "заметки — раздел версии из CHANGELOG.md" "[ -n \"\$changelog_line\" ] && grep -qF -- \"\$changelog_line\" '$TEST_DIR/notes.md'"
check "заметки — однострочник $repo" "grep -qF 'raw.githubusercontent.com/$repo/main/install.sh' '$TEST_DIR/notes.md'"
check "в заметках нет соседних разделов" "! grep -q '^## ' '$TEST_DIR/notes.md'"

# 2. Релиз (черновик) уже есть — повторный запуск дозаливает файлы и правит заметки и коммит.
dist=$(new_dist again)
if run_publish 1 "$dist" > "$TEST_DIR/out" 2>&1; then ok "повтор: скрипт прошёл"; else bad "повтор: скрипт упал: $(cat "$TEST_DIR/out")"; fi
upload=$(grep '^release upload ' "$TEST_DIR/gh.log" || true)
edit=$(grep '^release edit ' "$TEST_DIR/gh.log" || true)
check "повтор: второго create нет" "! grep -q '^release create ' '$TEST_DIR/gh.log'"
check "повтор: upload --clobber в $repo с архивом и суммами" "[[ \"\$upload\" == *'--clobber'* ]] && [[ \"\$upload\" == *'--repo $repo'* ]] && [[ \"\$upload\" == *'.zip checksums.txt'* ]]"
check "повтор: edit заметок и --target $sha" "[[ \"\$edit\" == *'--notes-file'* ]] && [[ \"\$edit\" == *\"--target $sha\"* ]] && [[ \"\$edit\" == *'--repo $repo'* ]]"

# 3. Суммы, с которыми архив прошёл проверку, не сходятся с архивом — ничего не выкладывается.
dist=$(new_dist tampered)
printf '%064d  Luna-1.0.0-macos-universal.zip\n' 0 > "$dist/checksums.txt"
if run_publish 0 "$dist" > "$TEST_DIR/out" 2>&1; then
  bad "чужие суммы: скрипт должен упасть"
else
  check "чужие суммы: отказ без вызовов gh" "[ ! -s '$TEST_DIR/gh.log' ]"
fi

# 4. Без GITHUB_SHA тег не на что ставить — отказ.
dist=$(new_dist nosha)
if env PATH="$TEST_DIR/bin:$PATH" GH_LOG="$TEST_DIR/gh.log" GH_NOTES="$TEST_DIR/notes.md" \
     GH_TOKEN=test GITHUB_SHA= sh scripts/publish-release.sh "$tag" "$dist" >/dev/null 2>&1; then
  bad "без GITHUB_SHA: скрипт должен упасть"
else
  ok "без GITHUB_SHA: отказ"
fi

if [ "$failures" -ne 0 ]; then
  echo "✗ publish-release.sh: проверок не прошло — $failures" >&2
  exit 1
fi
echo "✓ publish-release.sh: все проверки прошли"
