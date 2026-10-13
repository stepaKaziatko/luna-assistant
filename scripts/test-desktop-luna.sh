#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-desktop.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/LunaKit/LunaLook.swift \
    apps/macos/Sources/App/DesktopLunaLogic.swift \
    tests/DesktopLunaTests.swift -o "$TEST_DIR/desktop-luna-tests"
"$TEST_DIR/desktop-luna-tests"
