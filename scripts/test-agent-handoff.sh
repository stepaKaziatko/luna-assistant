#!/usr/bin/env bash
# «Открыть в…» (LUNA-79): план переноса сессии без окна (tests/AgentHandoffTests.swift) и
# инварианты исполнителя — только папка и ссылки через NSWorkspace и буфер обмена.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-handoff.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/AgentHandoffPlan.swift \
    apps/macos/Sources/App/AgentLaunchPlan.swift \
    apps/macos/Sources/App/AgentJumpPlan.swift \
    apps/macos/Sources/App/ChatProjects.swift \
    apps/macos/Sources/App/ProcessTTY.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    apps/macos/Sources/App/ClaudeHost.swift \
    tests/AgentHandoffTests.swift -o "$TEST_DIR/agent-handoff-tests"
"$TEST_DIR/agent-handoff-tests"

echo
echo "Executor"
files=(apps/macos/Sources/App/AgentHandoffPlan.swift apps/macos/Sources/App/AgentHandoff.swift
       apps/macos/Sources/App/AgentHandoffViews.swift)
for f in "${files[@]}"; do [ -f "$f" ] || { echo "  ✗ $f is missing"; exit 1; }; done
# Luna ничего не запускает и не скриптует: только открывает папку и ссылки.
if grep -n "Process()\|NSAppleScript\|osascript" "${files[@]}"; then
    echo "  ✗ handoff: a process or a script"; exit 1
fi
echo "  ✓ handoff: no process, no script"
# Перенос живёт только в памяти.
if grep -n "UserDefaults\.\|@AppStorage\|SecItem\|KeychainStore" "${files[@]}"; then
    echo "  ✗ handoff: written to UserDefaults or Keychain"; exit 1
fi
body=$(awk '/MARK: Перенос сессии \(LUNA-79\)/ { on = 1 } on { print } on && /^    #endif$/ { exit }' apps/macos/Sources/App/AppState.swift)
[ -n "$body" ] || { echo "  ✗ the handoff part of AppState not found"; exit 1; }
if echo "$body" | grep -n "UserDefaults\.\|@AppStorage\|SecItem\|KeychainStore"; then
    echo "  ✗ AppState: the handoff is written to UserDefaults or Keychain"; exit 1
fi
echo "  ✓ handoff: in memory only"
# Исполнитель и кнопка — не в App Store-сборке.
for f in "${files[@]}"; do
    head -20 "$f" | grep -q "^#if !APPSTORE" || { echo "  ✗ $f is not under #if !APPSTORE"; exit 1; }
done
echo "  ✓ plan, executor and button: GitHub build only"
# VS Code — тем же шагом «папка → ссылка», что «Перейти к агенту»; ожидание окна не копируется.
grep -q "AgentJump.openFolderThenLink(" apps/macos/Sources/App/AgentHandoff.swift \
    || { echo "  ✗ AgentHandoff does not reuse the folder → link step of AgentJump"; exit 1; }
if grep -n "sendWhenEditorIsUp\|linkReady\|CGWindowList" apps/macos/Sources/App/AgentHandoff.swift; then
    echo "  ✗ a second copy of the wait for the editor window"; exit 1
fi
echo "  ✓ VS Code: the shared folder → link step, no copy"
# Схема ссылки проверяется ещё раз перед открытием.
grep -q "AgentHandoffPlan.allowedSchemes" apps/macos/Sources/App/AgentHandoff.swift \
    || { echo "  ✗ the executor does not check the scheme"; exit 1; }
echo "  ✓ the executor checks the scheme"
# Перенос исполняется по событию хука, а не по пропаже сессии из списка.
grep -q "agentHandoffEvent(" apps/macos/Sources/App/HookServer.swift \
    || { echo "  ✗ HookServer does not feed the hook events to the handoff"; exit 1; }
set_sessions=$(awk '/func setAgentSessions\(/ { on = 1 } on { print } on && /^    }$/ { exit }' apps/macos/Sources/App/AppState.swift)
if echo "$set_sessions" | grep -n "Handoff"; then
    echo "  ✗ the handoff reacts to the list of sessions"; exit 1
fi
echo "  ✓ the handoff runs on SessionEnd only"
