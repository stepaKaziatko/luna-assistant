#!/bin/bash
# render-outfits.sh — compile and run the Mochi outfit planche renderer
# NOT in CI. Run manually: bash scripts/render-outfits.sh
# Output: /tmp/coucou-outfits.png

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
  apps/macos/Sources/CoucouKit/BotEngine.swift \
  apps/macos/Sources/CoucouKit/MochiOutfitDrawing.swift \
  scripts/RenderOutfits.swift \
  -framework AppKit \
  -framework SwiftUI \
  -o /tmp/coucou-render-outfits \
  2>&1

echo "Running renderer..."
/tmp/coucou-render-outfits
echo "Opening..."
open /tmp/coucou-outfits.png
