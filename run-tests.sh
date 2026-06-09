#!/bin/bash
# Framework-free unit checks that run with only the Command Line Tools (no Xcode
# needed). Each driver is compiled together with the real source file(s) it
# checks, so it exercises the actual implementation.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
status=0

run_check() {
  local name="$1"; shift
  echo "== $name =="
  if swiftc "$@" -o "$TMP/$name" && "$TMP/$name"; then :; else status=1; fi
  echo
}

run_check curve-checks \
  Sources/SyncBrightness/BrightnessCurve.swift \
  Tests/CurveChecks/main.swift

run_check hotkey-checks \
  -framework Cocoa -framework Carbon \
  Sources/SyncBrightness/HotKey.swift \
  Tests/HotKeyChecks/main.swift

run_check color-checks \
  Sources/SyncBrightness/ColorCorrection.swift \
  Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift \
  Sources/SyncBrightness/PatchCardLayout.swift \
  Sources/SyncBrightness/PatchCardAnalyzer.swift \
  Sources/SyncBrightness/ColorSyncMessages.swift \
  Sources/SyncBrightness/ColorSyncSession.swift \
  Sources/SyncBrightness/ColorSyncAdjust.swift \
  Sources/SyncBrightness/PairingPayload.swift \
  Sources/SyncBrightness/FrameCodec.swift \
  Sources/SyncBrightness/CaptureGate.swift \
  Sources/SyncBrightness/FieldSampler.swift \
  Tests/ColorChecks/main.swift
  # DisplayColorState.swift: needed for the DisplayColorState.formula tests in the same driver

exit "$status"
