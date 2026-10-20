#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-chat-cli.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    apps/macos/Sources/App/ChatCLI.swift \
    apps/macos/Sources/App/ChatHistory.swift \
    tests/ChatCLITests.swift -o "$TEST_DIR/chat-cli-tests"
"$TEST_DIR/chat-cli-tests"
