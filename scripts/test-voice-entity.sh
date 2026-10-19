#!/usr/bin/env bash
set -e
echo "Running EntityResolver tests…"
swiftc -o /tmp/voice-entity-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  apps/macos/Sources/App/Voice/VoiceIntent.swift \
  apps/macos/Sources/App/Voice/IntentParser.swift \
  apps/macos/Sources/App/Voice/VoiceQuery.swift \
  apps/macos/Sources/App/Voice/EntityResolver.swift \
  tests/EntityResolverTests.swift
/tmp/voice-entity-tests
