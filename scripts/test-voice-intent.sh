#!/usr/bin/env bash
set -e
echo "Running IntentParser tests…"
swiftc -o /tmp/voice-intent-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  apps/macos/Sources/App/Voice/VoiceIntent.swift \
  apps/macos/Sources/App/Voice/EntityResolver.swift \
  apps/macos/Sources/App/Voice/IntentParser.swift \
  apps/macos/Sources/App/Voice/VoiceQuery.swift \
  tests/IntentParserTests.swift
/tmp/voice-intent-tests
