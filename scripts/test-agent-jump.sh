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

# LUNA-68: каждый вариант релея кладёт корень проекта рядом с bundle_id, а между папкой и
# ссылкой на сессию нет фиксированной паузы.
HOOKS=apps/macos/Sources/App/HookServer.swift
bundle=$(grep -c "payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))" "$HOOKS")
project=$(grep -c "payload.setdefault('project_dir', env.get('CLAUDE_PROJECT_DIR', ''))" "$HOOKS")
if [ "$bundle" -lt 4 ] || [ "$bundle" != "$project" ]; then
    echo "  ✗ relay: bundle_id $bundle, project_dir $project"; exit 1
fi
echo "  ✓ relay: project_dir in all $project variants"
if grep -n "asyncAfter(deadline: .now() + 0.3)" apps/macos/Sources/App/AgentJump.swift; then
    echo "  ✗ AgentJump: a fixed 0.3 s pause before the session link"; exit 1
fi
echo "  ✓ AgentJump: the link waits for the editor, no fixed pause"
# Событие несёт project_dir в книгу сессий, а переход к агенту считается его просмотром.
grep -q 'projectDir: AgentJumpPlan.validFolder(payload\["project_dir"\] as? String ?? "") ?? ""' "$HOOKS" \
    || { echo "  ✗ HookServer: project_dir of the event does not reach the session book"; exit 1; }
awk '/func goToAgent\(/ { on = 1 } on { print } on && /^    }$/ { exit }' apps/macos/Sources/App/AppState.swift \
    | grep -q "HookServer.shared.markAgentsSeen(for: session.key)" \
    || { echo "  ✗ goToAgent does not mark the session seen"; exit 1; }
echo "  ✓ project_dir reaches the book; going to the agent marks it seen"
