#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-shortcuts.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# ShortcutLogic.islandShortcuts читает таблицу клавиш острова, а та знает страницы (IslandView).
swiftc apps/macos/Sources/App/ShortcutLogic.swift \
    apps/macos/Sources/App/IslandKeys.swift \
    tests/IslandTypeStubs.swift \
    tests/ShortcutTests.swift -o "$TEST_DIR/shortcut-tests"
"$TEST_DIR/shortcut-tests"
