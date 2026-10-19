#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-jump.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/AgentJumpPlan.swift \
    apps/macos/Sources/App/ProcessTTY.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    apps/macos/Sources/App/ClaudeHost.swift \
    tests/AgentJumpTests.swift -o "$TEST_DIR/agent-jump-tests"
"$TEST_DIR/agent-jump-tests"
