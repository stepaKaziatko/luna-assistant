#!/usr/bin/env bash
# Проекты (LUNA-75): список и путь, папка на диске, хранение, проект агента, импорт путей из
# ~/.claude.json и ~/.codex/config.toml (фикстуры tests/fixtures/projects), группы агентов.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-chat-projects.XXXXXX")"
trap 'chmod -R u+rwx "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/work"
swiftc \
    apps/macos/Sources/App/ChatProjects.swift \
    apps/macos/Sources/App/AgentProjectGroups.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    tests/ChatProjectsTests.swift -o "$TEST_DIR/bin/chat-projects-tests"
"$TEST_DIR/bin/chat-projects-tests" "$PWD/tests/fixtures/projects" "$TEST_DIR/work"
