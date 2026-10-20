#!/usr/bin/env bash
# Живой прогон тех же аргументов, что у чата, настоящим `claude` на дешёвой модели (haiku).
# Тратит подписку (несколько токенов), поэтому по умолчанию пропускается: LUNA_LIVE_CLI=1.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${LUNA_LIVE_CLI:-}" != "1" ]; then
    echo "пропущено: живой прогон включается LUNA_LIVE_CLI=1"
    exit 0
fi
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-claude-live.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    apps/macos/Sources/App/ChatCLI.swift \
    apps/macos/Sources/App/ClaudeStreamParser.swift \
    apps/macos/Sources/App/ChatCLIMessages.swift \
    apps/macos/Sources/App/ClaudeCLIChat.swift \
    apps/macos/Sources/App/ChatProjects.swift \
    tests/ClaudeCLILiveTest.swift -o "$TEST_DIR/claude-cli-live"
"$TEST_DIR/claude-cli-live" "$TEST_DIR"
