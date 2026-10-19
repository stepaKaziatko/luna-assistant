#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-peek.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/AgentPeek.swift \
    apps/macos/Sources/App/AgentNotch.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    tests/AgentPeekTests.swift -o "$TEST_DIR/agent-peek-tests"
"$TEST_DIR/agent-peek-tests"
