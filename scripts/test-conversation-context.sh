#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/conversation-context-tests
echo "=== ConversationContext tests ==="
swiftc -swift-version 6 -strict-concurrency=complete \
    "$ROOT/tests/VoiceTestStubs.swift" \
    "$ROOT/tests/PillFixture.swift" \
    "$ROOT/apps/macos/Sources/App/Voice/VoiceIntent.swift" \
    "$ROOT/apps/macos/Sources/App/Voice/IntentParser.swift" \
    "$ROOT/apps/macos/Sources/App/Voice/VoiceQuery.swift" \
    "$ROOT/apps/macos/Sources/App/Voice/EntityResolver.swift" \
    "$ROOT/apps/macos/Sources/App/Voice/ConversationContext.swift" \
    "$ROOT/tests/ConversationContextTests.swift" \
    -o "$OUT"
"$OUT"
