#!/bin/sh
# Упаковывает ядро без оболочки: для ОС, где приложения Luna ещё нет. Архив содержит
# скомпилированное ядро (JSON-RPC на stdio, см. protocol/README.md); нужен только Node.
# Перед упаковкой проверяет, что ядро на этой ОС отвечает на core.hello.
#
#   scripts/pack-core.sh <платформа> <каталог для архива>     # → luna-core-0.2.0-linux.tar.gz
set -eu

platform="$1"
out_dir="$(mkdir -p "$2" && cd "$2" && pwd)"
cd "$(dirname "$0")/.."

version=$(scripts/check-version.sh)
name="luna-core-$version-$platform"
stage="$(mktemp -d)"
data_dir="$(mktemp -d)"
trap 'rm -rf "$stage" "$data_dir"' EXIT

npm run build --silent
mkdir "$stage/$name"
(cd core/dist && find . -name '*.js' | tar -cf - -T -) | tar -xf - -C "$stage/$name"
printf '{ "name": "luna-core", "version": "%s", "type": "module", "engines": { "node": ">=22.18" } }\n' "$version" \
  > "$stage/$name/package.json"

# Ядро завершается, как только закрыт stdin, поэтому держим его открытым, пока не придёт ответ.
reply=$( (printf '{"jsonrpc":"2.0","id":1,"method":"core.hello","params":{}}\n'; sleep 3) \
  | LUNA_DATA_DIR="$data_dir" node "$stage/$name/main.js" 2>/dev/null )
case "$reply" in
  *"\"version\":\"$version\""*) ;;
  *) printf '✗ ядро не ответило на core.hello: %s\n' "$reply" >&2; exit 1 ;;
esac

tar -czf "$out_dir/$name.tar.gz" -C "$stage" "$name"
echo "$out_dir/$name.tar.gz"
