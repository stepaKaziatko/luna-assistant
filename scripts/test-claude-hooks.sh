#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-claude-hooks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/ClaudeHookDetection.swift \
    tests/ClaudeHookDetectionTests.swift -o "$TEST_DIR/claude-hooks-tests"
"$TEST_DIR/claude-hooks-tests"
