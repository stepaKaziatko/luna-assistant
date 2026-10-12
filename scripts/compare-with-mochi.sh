#!/usr/bin/env bash
# compare-with-mochi.sh — насколько силуэт и цвет Luna отличаются от Mochi из coucou.
# Скачивает файлы персонажа upstream (коммит из LICENSE-COUCOU), собирает два бинаря
# (Mochi и рабочая копия), рисует кадры 200 × 200 pt и печатает пересечение силуэтов (IoU).
# Нужны gh и сеть; в CI не входит. Порог IoU — LUNA_MAX_IOU (по умолчанию 0.85).
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_REF="${LUNA_UPSTREAM_REF:-0dffbaf}"
MAX_IOU="${LUNA_MAX_IOU:-0.85}"
STATES="${LUNA_STATES:-idle working approval sleeping error}"
FILES="BotEngine MochiOutfitDrawing MochiWardrobe IslandTypes IslandScreenGeometry"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
T="$(mktemp -d "${TMPDIR:-/tmp}/luna-compare.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mochi"

echo "Скачиваю upstream $UPSTREAM_REF..."
for f in $FILES; do
  gh api "repos/Louis-CFM/coucou/contents/NotchBuddy/Sources/CoucouKit/$f.swift?ref=$UPSTREAM_REF" \
    -H 'Accept: application/vnd.github.raw' > "$T/mochi/$f.swift"
done

build() { # <out> <sources...>
  local out="$1"; shift
  swiftc -parse-as-library -sdk "$SDK" "$@" scripts/RenderStubs.swift scripts/CompareFrame.swift \
    -framework AppKit -framework SwiftUI -o "$out" 2>&1 | { grep -v "warning:" || true; }
}
echo "Собираю Mochi и Luna..."
build "$T/mochi-frame" $(for f in $FILES; do echo "$T/mochi/$f.swift"; done)
build "$T/luna-frame" $(for f in $FILES; do echo "apps/macos/Sources/CoucouKit/$f.swift"; done) \
  apps/macos/Sources/CoucouKit/LunaLook.swift apps/macos/Sources/CoucouKit/LunaFace.swift
swiftc -sdk "$SDK" scripts/MaskIoU.swift -framework AppKit -o "$T/mask-iou" 2>&1 | { grep -v "warning:" || true; }

fail=0
for s in $STATES; do
  "$T/mochi-frame" "$T/mochi-$s.png" "$s"
  "$T/luna-frame" "$T/luna-$s.png" "$s"
  line="$("$T/mask-iou" "$T/mochi-$s.png" "$T/luna-$s.png")"
  echo "$s: $line"
  iou="${line#IoU=}"; iou="${iou%% *}"
  if awk "BEGIN{exit !($iou > $MAX_IOU)}"; then fail=1; echo "  слишком похоже на Mochi (порог $MAX_IOU)"; fi
done
exit $fail
