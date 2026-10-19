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
