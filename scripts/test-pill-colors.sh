#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-pill-colors.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/LunaKit/PillColors.swift \
    tests/PillColorsTests.swift -o "$TEST_DIR/pill-colors-tests"
"$TEST_DIR/pill-colors-tests"
