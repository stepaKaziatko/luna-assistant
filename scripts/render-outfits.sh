#!/bin/bash
# render-outfits.sh — лист кадров персонажа: наряды, состояния, глаза (реальным BotEngine)
# NOT in CI. Run manually: bash scripts/render-outfits.sh
# Output: /tmp/luna-outfits.png, luna-roll.png, luna-transition.png, luna-states.png

set -e
cd "$(dirname "$0")/.."

SDK=$(xcrun --sdk macosx --show-sdk-path)

echo "Compiling renderer..."
swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macosx15.0 \
  apps/macos/Sources/CoucouKit/IslandScreenGeometry.swift \
  apps/macos/Sources/CoucouKit/IslandTypes.swift \
  apps/macos/Sources/CoucouKit/MochiWardrobe.swift \
  apps/macos/Sources/CoucouKit/LunaLook.swift \
  apps/macos/Sources/CoucouKit/LunaFace.swift \
  apps/macos/Sources/CoucouKit/BotEngine.swift \
  apps/macos/Sources/CoucouKit/MochiOutfitDrawing.swift \
  scripts/RenderStubs.swift \
  scripts/RenderOutfits.swift \
  -framework AppKit \
  -framework SwiftUI \
  -o /tmp/luna-render-outfits \
  2>&1

echo "Running renderer..."
/tmp/luna-render-outfits
echo "Done: /tmp/luna-outfits.png"
[ -n "${CI:-}" ] || open /tmp/luna-outfits.png
