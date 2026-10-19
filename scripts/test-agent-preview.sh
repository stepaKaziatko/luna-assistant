#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-preview.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/AgentPreviewLogic.swift \
    apps/macos/Sources/App/AgentJumpPlan.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    tests/AgentPreviewTests.swift -o "$TEST_DIR/agent-preview-tests"
"$TEST_DIR/agent-preview-tests"
