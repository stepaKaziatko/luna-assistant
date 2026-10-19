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

# LUNA-68: «Свернуть шторку» сворачивает, не забирая фокус, и регистрируется по смене режима острова.
CTRL=apps/macos/Sources/App/IslandWindowController.swift
block=$(awk '/case \.collapseIsland:/ { on = 1; next } on && /case \./ { exit } on && !/^[[:space:]]*\/\// { print }' "$CTRL")
echo "$block" | grep -q "collapse(allowPendingApproval: true)" || { echo "  ✗ collapseIsland does not collapse"; exit 1; }
if echo "$block" | grep -Eq "makeKey|NSApp\.activate|activate\("; then echo "  ✗ collapseIsland takes the focus"; exit 1; fi
grep -q "HotKeyCenter.shared.setIslandExpanded(mode == .expanded)" "$CTRL" || { echo "  ✗ ⌘⎋ is not tied to the island mode"; exit 1; }
echo "  ✓ collapseIsland: collapse(allowPendingApproval: true), no makeKey / activate; registered by island mode"
