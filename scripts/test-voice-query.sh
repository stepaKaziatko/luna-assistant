#!/usr/bin/env bash
set -e
echo "Running VoiceQuery tests…"
swiftc -o /tmp/voice-query-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  apps/macos/Sources/App/Voice/VoiceIntent.swift \
  apps/macos/Sources/App/Voice/EntityResolver.swift \
  apps/macos/Sources/App/Voice/IntentParser.swift \
  apps/macos/Sources/App/Voice/VoiceQuery.swift \
  tests/VoiceQueryTests.swift
/tmp/voice-query-tests
