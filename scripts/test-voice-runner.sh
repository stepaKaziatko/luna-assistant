#!/usr/bin/env bash
set -e
echo "Running VoiceActionRunner tests…"
swiftc -o /tmp/voice-runner-tests \
  tests/VoiceTestStubs.swift \
  tests/PillFixture.swift \
  apps/macos/Sources/App/Voice/VoiceIntent.swift \
  apps/macos/Sources/App/Voice/IntentParser.swift \
  apps/macos/Sources/App/Voice/VoiceQuery.swift \
  apps/macos/Sources/App/Voice/EntityResolver.swift \
  apps/macos/Sources/App/Voice/VoiceActionRunner.swift \
  tests/VoiceActionRunnerTests.swift
/tmp/voice-runner-tests
