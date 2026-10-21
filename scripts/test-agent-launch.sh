#!/usr/bin/env bash
# Запуск агента из Luna (LUNA-77): план запуска без окна (tests/AgentLaunchTests.swift).
# Кнопки и исполнителя нет с LUNA-80; план и проверка установленных приложений остались для
# «Открыть в…» (LUNA-79).
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
# Остатки — не в App Store-сборке.
for f in apps/macos/Sources/App/AgentLaunch.swift apps/macos/Sources/App/AgentLaunchViews.swift; do
    head -20 "$f" | grep -q "^#if !APPSTORE" || { echo "  ✗ $f is not under #if !APPSTORE"; exit 1; }
done
echo "  ✓ installed apps and target names: GitHub build only"
# Кнопки «Запустить агента» нет (LUNA-80): запрос с проектом сам запускает агента в фоне.
# Остались план и проверка установленных приложений — на них опирается «Открыть в…» (LUNA-79).
if grep -n "AgentLaunchButton\|AgentLaunchMenuView\|func launchAgent\|static func run(" \
        apps/macos/Sources/App/AgentLaunch*.swift apps/macos/Sources/App/AppState.swift apps/macos/Sources/App/IslandViewContent.swift; then
    echo "  ✗ the Launch agent button or its executor is still there"; exit 1
fi
echo "  ✓ no Launch agent button and no executor (LUNA-80)"
