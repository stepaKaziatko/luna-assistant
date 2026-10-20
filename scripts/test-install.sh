#!/usr/bin/env bash
# Проверяет установщик install.sh без сети: синтаксис, репозиторий релизов, минимум macOS,
# установку поддельного бандла из каталога, отказ при чужой контрольной сумме и то, из какого
# репозитория берутся файлы старых и новых релизов (curl подменяется заглушкой).
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

failures=0
ok() { printf '✓ %s\n' "$1"; }
bad() { printf '✗ %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

unset LUNA_VERSION LUNA_DOWNLOAD_BASE LUNA_INSTALL_DIR
repo="stepaKaziatko/luna-assistant"

check "sh -n install.sh" "sh -n install.sh"
check "релизы — из $repo" "grep -qxF 'repo=\"$repo\"' install.sh"

archive_repo=$(sed -n 's/^archive_repo="\(.*\)"$/\1/p' install.sh)
check "у старых релизов свой репозиторий-архив" "[ -n '$archive_repo' ] && [ '$archive_repo' != '$repo' ]"

min_macos=$(sed -n 's/^min_macos=//p' install.sh)
target=$(awk '/^  deploymentTarget:/ { getline; gsub(/[^0-9.]/, ""); print; exit }' apps/macos/project.yml)
check "min_macos ($min_macos) = мажор deploymentTarget.macOS ($target)" "[ -n '$min_macos' ] && [ '$min_macos' = '${target%%.*}' ]"

# Поддельный релиз v9.9.9 в каталоге: архив с Luna.app и checksums.txt.
dist="$TEST_DIR/dist"
mkdir -p "$dist" "$TEST_DIR/app/Luna.app/Contents/MacOS"
printf 'stub\n' > "$TEST_DIR/app/Luna.app/Contents/MacOS/Luna"
ditto -c -k --keepParent "$TEST_DIR/app/Luna.app" "$dist/Luna-9.9.9-macos-universal.zip"
(cd "$dist" && shasum -a 256 -- *.zip > checksums.txt)

install_dir="$TEST_DIR/fresh/A"
if out=$(LUNA_VERSION=v9.9.9 LUNA_DOWNLOAD_BASE="file://$dist" LUNA_INSTALL_DIR="$install_dir" sh install.sh 2>&1) &&
   [ -f "$install_dir/Luna.app/Contents/MacOS/Luna" ]; then
  ok "ставит бандл из каталога в пустую папку"
else
  bad "ставит бандл из каталога в пустую папку: $out"
fi

printf '%064d  Luna-9.9.9-macos-universal.zip\n' 0 > "$dist/checksums.txt"
set +e
out=$(LUNA_VERSION=v9.9.9 LUNA_DOWNLOAD_BASE="file://$dist" LUNA_INSTALL_DIR="$TEST_DIR/broken/A" sh install.sh 2>&1)
rc=$?
set -e
check "чужая контрольная сумма — отказ (rc=$rc)" "[ $rc -ne 0 ] && [[ \"\$out\" == *'контрольная сумма'* ]] && [ ! -e '$TEST_DIR/broken/A/Luna.app' ]"

# Заглушка curl: пишет адреса в журнал, на запрос последнего релиза отвечает $FAKE_LATEST,
# скачивание проваливает — установщик останавливается, успев назвать адрес архива.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/bin/sh
for arg; do last="$arg"; done
printf '%s\n' "$last" >> "$CURL_LOG"
case " $* " in
  *" -w "*) printf '%s' "$FAKE_LATEST"; exit 0 ;;
esac
exit 22
STUB
chmod +x "$TEST_DIR/bin/curl"

# Откуда скачивается архив тега: печатает адрес первого скачивания.
download_url() {
  local log="$TEST_DIR/curl-$RANDOM.log"
  : > "$log"
  env PATH="$TEST_DIR/bin:$PATH" CURL_LOG="$log" FAKE_LATEST="${2:-}" \
    ${1:+LUNA_VERSION=$1} LUNA_INSTALL_DIR="$TEST_DIR/never/A" sh install.sh >/dev/null 2>&1 || true
  grep '/releases/download/' "$log" | head -n 1
}

expect_from() {
  local label="$1" want="$2" url="$3"
  check "$label → $url" "[ '$url' = '$want' ]"
}

for tag in v1.0.0 v0.7.0 v0.2.0; do
  expect_from "$tag из архива" \
    "https://github.com/$archive_repo/releases/download/$tag/Luna-${tag#v}-macos-universal.zip" \
    "$(download_url "$tag")"
done
for tag in v1.1.0 v1.0.1 v2.0.0; do
  expect_from "$tag из $repo" \
    "https://github.com/$repo/releases/download/$tag/Luna-${tag#v}-macos-universal.zip" \
    "$(download_url "$tag")"
done

# Без LUNA_VERSION: последний релиз спрашивается у luna-assistant. Пока там последний — v1.0.0
# без файлов, архив берётся из архива; после выпуска 1.1.0 — из luna-assistant.
log="$TEST_DIR/latest.log"
: > "$log"
env PATH="$TEST_DIR/bin:$PATH" CURL_LOG="$log" \
  FAKE_LATEST="https://github.com/$repo/releases/tag/v1.0.0" \
  LUNA_INSTALL_DIR="$TEST_DIR/never/A" sh install.sh >/dev/null 2>&1 || true
check "последний релиз — у $repo" "grep -qxF 'https://github.com/$repo/releases/latest' '$log'"
expect_from "последний v1.0.0 из архива" \
  "https://github.com/$archive_repo/releases/download/v1.0.0/Luna-1.0.0-macos-universal.zip" \
  "$(download_url "" "https://github.com/$repo/releases/tag/v1.0.0")"
expect_from "последний v1.1.0 из $repo" \
  "https://github.com/$repo/releases/download/v1.1.0/Luna-1.1.0-macos-universal.zip" \
  "$(download_url "" "https://github.com/$repo/releases/tag/v1.1.0")"

if [ "$failures" -ne 0 ]; then
  echo "✗ install.sh: проверок не прошло — $failures" >&2
  exit 1
fi
echo "✓ install.sh: все проверки прошли"
