#!/usr/bin/env bash
# Страницы острова: домашняя страница, каталог страниц интеграций (когда есть вкладка GitHub),
# раскладка каждого IslandView. Без окна: модель собирается вместе с настоящим IslandTypes.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-integration-pages.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    apps/macos/Sources/LunaKit/IslandScreenGeometry.swift \
    apps/macos/Sources/LunaKit/IslandTypes.swift \
    apps/macos/Sources/App/IntegrationPages.swift \
    tests/IntegrationPagesTests.swift -o "$TEST_DIR/integration-pages-tests"
"$TEST_DIR/integration-pages-tests"

# LUNA-68: после ответа нет безусловного перехода на главную — решает IslandHome.afterRequest.
HOOKS=apps/macos/Sources/App/HookServer.swift
for fn in "func removeApproval" "func dismissQuestionCard" "func sendApprovalDecision"; do
    body=$(awk -v f="$fn" 'index($0, f) { on = 1 } on { print } on && /^    }$/ { exit }' "$HOOKS")
    if echo "$body" | grep -q "goHome()"; then echo "  ✗ $fn still calls goHome()"; exit 1; fi
    if ! echo "$body" | grep -q "closeRequestCard("; then echo "  ✗ $fn does not ask IslandHome.afterRequest"; exit 1; fi
done
echo "  ✓ removeApproval, dismissQuestionCard, sendApprovalDecision: no unconditional goHome()"
