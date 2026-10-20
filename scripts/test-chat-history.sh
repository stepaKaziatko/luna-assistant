#!/usr/bin/env bash
# История чатов (LUNA-76): заголовок, запись и чтение, порядок, лимит 100, удаление, испорченный
# файл, права 0600, продолжение чата (resume / новая сессия / пометка), ход после «+».
# Пишет только во временную папку: настоящую ~/Library/Application Support/Luna не трогает.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-chat-history.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/work"
swiftc \
    apps/macos/Sources/App/ChatHistory.swift \
    apps/macos/Sources/App/ChatCLI.swift \
    tests/ChatHistoryTests.swift -o "$TEST_DIR/bin/chat-history-tests"
"$TEST_DIR/bin/chat-history-tests" "$TEST_DIR/work"
