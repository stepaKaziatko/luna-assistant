#!/usr/bin/env bash
# Агент в проекте (LUNA-80): аргументы, окружение, план запуска и процесс против поддельного
# `claude` (tests/fake_claude_cli.sh), маршрут хуков агента Luna. Живой `claude` не нужен.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-agent-run.XXXXXX")"
trap 'pkill -f "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
APP=apps/macos/Sources/App
swiftc \
    $APP/ChatCLI.swift \
    $APP/ClaudeStreamParser.swift \
    $APP/ChatCLIMessages.swift \
    $APP/ClaudeCLIChat.swift \
    $APP/ChatProjects.swift \
    $APP/ClaudeAgentRun.swift \
    $APP/AgentSessions.swift \
    $APP/PillSessionRegistry.swift \
    $APP/ClaudeHost.swift \
    $APP/AgentJumpPlan.swift \
    $APP/ProcessTTY.swift \
    $APP/ApprovalQueue.swift \
    tests/ClaudeAgentRunTests.swift -o "$TEST_DIR/agent-run-tests"
"$TEST_DIR/agent-run-tests" "$PWD/tests/fixtures/claude-cli" "$PWD/tests/fake_claude_cli.sh" "$TEST_DIR"

echo
echo "Sources"
# Подпроцесс `claude` запускается только из двух мест (инвариант CLAUDE.md).
launchers=$(grep -lE "arguments = (ClaudeCLIArguments|ClaudeAgentArguments)\.build" $APP/*.swift || true)
expected="$APP/ClaudeAgentRun.swift
$APP/ClaudeCLIChat.swift"
[ "$(echo "$launchers" | sort)" = "$expected" ] \
    || { echo "  ✗ claude is started elsewhere:"; echo "$launchers"; exit 1; }
echo "  ✓ claude is started only from ClaudeCLIChat.swift and ClaudeAgentRun.swift"
# Режима «только чтение» больше нет (LUNA-80, решение В2).
if grep -n "projectTools\|projectDisallowedTools\|inProject" $APP/ClaudeCLIChat.swift; then
    echo "  ✗ the read-only project mode is still in ClaudeCLIChat.swift"; exit 1
fi
echo "  ✓ no read-only project mode in ClaudeCLIChat.swift"
# Сторожа тишины у агента нет.
if grep -n "idleTimeout\|makeTimerSource" $APP/ClaudeAgentRun.swift; then
    echo "  ✗ the agent has a silence watchdog"; exit 1
fi
echo "  ✓ the agent has no silence watchdog"
# Агент — только в сборке GitHub.
for f in $APP/ClaudeAgentRun.swift $APP/ClaudeAgentController.swift; do
    head -1 "$f" | grep -q "^#if !APPSTORE" || { echo "  ✗ $f is not under #if !APPSTORE"; exit 1; }
done
echo "  ✓ the agent: GitHub build only"
# HookServer: агент Luna идёт первым в маршруте события, а его запрос разрешения — в очередь.
event=$(awk '/private func processEvent\(/ { on = 1 } on { print } on && /Ignored/ { exit }' $APP/HookServer.swift)
echo "$event" | grep -q 'LunaHookOrigin.of(payload) == .agent' \
    || { echo "  ✗ processEvent does not route Luna agents before the rest"; exit 1; }
first_route=$(echo "$event" | grep -n "if LunaHookOrigin.of(payload) == .agent\|if isCodexEvent" | head -1)
echo "$first_route" | grep -q LunaHookOrigin || { echo "  ✗ Luna agents are not routed first"; exit 1; }
perm=$(awk '/private func processPermissionRequest\(/ { on = 1 } on { print } on && /let tool = payload/ { exit }' $APP/HookServer.swift)
echo "$perm" | grep -q 'guard isLunaAgent ||' \
    || { echo "  ✗ a Luna agent's permission request is not taken to the island"; exit 1; }
echo "  ✓ HookServer: Luna agents first, their permission requests go to the island"
# Выход из Luna останавливает агентов и спрашивает, если кто-то посреди хода.
grep -q "func applicationShouldTerminate" $APP/AppDelegate.swift \
    && grep -q "ClaudeAgentProcess.terminateAllAndWait()" $APP/AppDelegate.swift \
    || { echo "  ✗ quitting does not stop the agents"; exit 1; }
echo "  ✓ quitting stops the agents (with a confirmation mid-turn)"
# Кнопки «Запустить агента» больше нет.
if grep -n "AgentLaunchButton" $APP/IslandViewContent.swift; then
    echo "  ✗ the Launch agent button is still on the prompt page"; exit 1
fi
echo "  ✓ no Launch agent button on the prompt page"
# Запуски агента в историю чатов не пишутся.
if grep -n "recordOpenChat\|chatHistory.append\|ChatHistoryRecord\|chatHistoryStore" $APP/ClaudeAgentController.swift; then
    echo "  ✗ an agent run touches the chat history"; exit 1
fi
echo "  ✓ agent runs are not written to the chat history"
