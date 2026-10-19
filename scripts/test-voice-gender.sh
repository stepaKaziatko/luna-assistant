#!/usr/bin/env bash
set -e
echo "Running VoiceGenderNames tests…"
swiftc -o /tmp/voice-gender-tests \
  apps/macos/Sources/App/Voice/VoiceGenderNames.swift \
  tests/VoiceGenderTests.swift
/tmp/voice-gender-tests
