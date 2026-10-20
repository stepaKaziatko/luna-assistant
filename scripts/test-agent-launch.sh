#!/usr/bin/env bash
# Запуск агента из Luna (LUNA-77): план запуска без окна (tests/AgentLaunchTests.swift) и
# инварианты исполнителя — только ссылки и папки через NSWorkspace.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-launch.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc apps/macos/Sources/App/AgentLaunchPlan.swift \
    apps/macos/Sources/App/AgentJumpPlan.swift \
    apps/macos/Sources/App/ChatProjects.swift \
    apps/macos/Sources/App/ProcessTTY.swift \
    apps/macos/Sources/App/AgentSessions.swift \
    apps/macos/Sources/App/PillSessionRegistry.swift \
    apps/macos/Sources/App/ClaudeHost.swift \
    tests/AgentLaunchTests.swift -o "$TEST_DIR/agent-launch-tests"
"$TEST_DIR/agent-launch-tests"

echo
echo "Executor"
# Luna ничего не запускает и не скриптует: только открывает папку и ссылки.
if grep -n "Process()\|NSAppleScript\|osascript" apps/macos/Sources/App/AgentLaunch*.swift; then
    echo "  ✗ AgentLaunch: a process or a script"; exit 1
fi
echo "  ✓ AgentLaunch: no process, no script"
# Папка расширений VS Code — только список имён.
hits=$(grep -rn "\.vscode/extensions" apps/macos/Sources || true)
if [ -z "$hits" ] || echo "$hits" | grep -v "contentsOfDirectory" >/dev/null; then
    echo "  ✗ the extensions folder is read other than by the list of names:"; echo "$hits"; exit 1
fi
echo "  ✓ the extensions folder: the list of names only"
# Исполнитель и кнопка — не в App Store-сборке.
for f in apps/macos/Sources/App/AgentLaunch.swift apps/macos/Sources/App/AgentLaunchViews.swift; do
    head -20 "$f" | grep -q "^#if !APPSTORE" || { echo "  ✗ $f is not under #if !APPSTORE"; exit 1; }
done
echo "  ✓ executor and button: GitHub build only"
# Ссылку VS Code исполнитель шлёт тем же шагом «папка → ссылка», что и «Перейти к агенту».
grep -q "AgentJump.openFolderThenLink(" apps/macos/Sources/App/AgentLaunch.swift \
    || { echo "  ✗ AgentLaunch does not reuse the folder → link step of AgentJump"; exit 1; }
[ "$(grep -c "func sendWhenEditorIsUp" apps/macos/Sources/App/AgentJump.swift)" = 1 ] \
    && ! grep -q "sendWhenEditorIsUp\|linkReady" apps/macos/Sources/App/AgentLaunch.swift \
    || { echo "  ✗ a second copy of the wait for the editor window"; exit 1; }
echo "  ✓ VS Code: the shared folder → link step, no copy"
# Запуск не пишет в историю чатов и сворачивает остров.
body=$(awk '/func launchAgent\(/ { on = 1 } on { print } on && /^    }$/ { exit }' apps/macos/Sources/App/AppState.swift)
[ -n "$body" ] || { echo "  ✗ AppState.launchAgent not found"; exit 1; }
if echo "$body" | grep -n "chatHistory\|recordChat\|ChatMessage"; then
    echo "  ✗ the launch touches the chat history"; exit 1
fi
echo "$body" | grep -q "islandCollapseAfterJump" || { echo "  ✗ the launch does not fold the island"; exit 1; }
echo "  ✓ launch: not in the chat history, the island folds"
