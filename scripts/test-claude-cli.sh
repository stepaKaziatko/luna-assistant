#!/usr/bin/env bash
# Разбор потока Claude Code на фикстурах и запуск против поддельного `claude` (tests/fake_claude_cli.sh).
# Живой `claude` не нужен и подписку не тратит.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-claude-cli.XXXXXX")"
trap 'pkill -f "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
swiftc \
    apps/macos/Sources/App/ChatCLI.swift \
    apps/macos/Sources/App/ClaudeStreamParser.swift \
    apps/macos/Sources/App/ChatCLIMessages.swift \
    apps/macos/Sources/App/ClaudeCLIChat.swift \
    apps/macos/Sources/App/ChatProjects.swift \
    tests/ClaudeCLIChatTests.swift -o "$TEST_DIR/claude-cli-tests"
"$TEST_DIR/claude-cli-tests" "$PWD/tests/fixtures/claude-cli" "$PWD/tests/fake_claude_cli.sh" "$TEST_DIR"
