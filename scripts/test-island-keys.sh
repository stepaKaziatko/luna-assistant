#!/usr/bin/env bash
# Клавиши острова: таблица привязок, сопоставление клавиши с командой, сетка плиток, двухшаговый
# ответ, правило хоткея страницы. Без окна: файлы Foundation-only.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-island-keys.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    apps/macos/Sources/App/IslandKeys.swift \
    apps/macos/Sources/App/ShortcutLogic.swift \
    tests/IslandTypeStubs.swift \
    tests/IslandKeysTests.swift -o "$TEST_DIR/island-keys-tests"
"$TEST_DIR/island-keys-tests"
