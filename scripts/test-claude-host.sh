#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-claude-host.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/ClaudeHost.swift \
    tests/ClaudeHostTests.swift -o "$TEST_DIR/claude-host-tests"
"$TEST_DIR/claude-host-tests"
