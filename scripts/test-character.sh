#!/usr/bin/env bash
# Кадровый тест персонажа: рисует настоящий BotEngine через ImageRenderer и проверяет кадры
# (тело на месте и в холсте, наряды видны, глаза внутри тела, все 13 форм глаз рисуются).
# Сеть и upstream не нужны.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-character.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -sdk "$SDK" \
    apps/macos/Sources/LunaKit/IslandScreenGeometry.swift \
    apps/macos/Sources/LunaKit/IslandTypes.swift \
    apps/macos/Sources/LunaKit/LunaWardrobe.swift \
    apps/macos/Sources/LunaKit/LunaLook.swift \
    apps/macos/Sources/LunaKit/LunaFace.swift \
    apps/macos/Sources/LunaKit/BotEngine.swift \
    apps/macos/Sources/LunaKit/LunaOutfitDrawing.swift \
    scripts/RenderStubs.swift \
    tests/CharacterFrameTests.swift \
    -framework AppKit -framework SwiftUI \
    -o "$TEST_DIR/character-tests" 2>&1 | { grep -v "warning:" || true; }
"$TEST_DIR/character-tests"
