#!/usr/bin/env bash
set -e
echo "Running WakeWindowBackoff tests…"
swiftc -o /tmp/voice-backoff-tests \
  apps/macos/Sources/App/Voice/WakeWindowBackoff.swift \
  tests/WakeWindowBackoffTests.swift
/tmp/voice-backoff-tests
