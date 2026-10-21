#!/usr/bin/env bash
# Живой прогон агента в проекте (LUNA-80) настоящим `claude` на дешёвой модели (haiku): разрешение
# хуком, отказ без решения, продолжение той же сессии. Изолирован: временная папка, свой хук через
# `--settings`, `--setting-sources project`; сокет Luna и ~/.claude/settings.json не трогаются.
# Тратит подписку (несколько токенов), поэтому по умолчанию пропускается: LUNA_LIVE_CLI=1.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${LUNA_LIVE_CLI:-}" != "1" ]; then
    echo "пропущено: живой прогон включается LUNA_LIVE_CLI=1"
    exit 0
fi
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-live.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP=apps/macos/Sources/App
swiftc \
    $APP/ChatCLI.swift \
    $APP/ClaudeStreamParser.swift \
    $APP/ChatCLIMessages.swift \
    $APP/ClaudeCLIChat.swift \
    $APP/ChatProjects.swift \
    $APP/ClaudeAgentRun.swift \
    tests/ClaudeAgentRunLiveTest.swift -o "$TEST_DIR/agent-run-live"
"$TEST_DIR/agent-run-live" "$TEST_DIR"
