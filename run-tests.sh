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

run_check resolver-checks \
  -framework CoreGraphics \
  Sources/SyncBrightness/DisplayResolver.swift \
  Tests/ResolverChecks/main.swift

run_check gamma-checks \
  -framework CoreGraphics \
  Sources/SyncBrightness/BrightnessCurve.swift \
  Sources/SyncBrightness/GammaDimmer.swift \
  Tests/GammaChecks/main.swift

run_check first-sight-checks \
  Sources/SyncBrightness/FirstSight.swift \
  Tests/FirstSightChecks/main.swift

run_check hotkey-checks \
  -framework Cocoa -framework Carbon \
  Sources/SyncBrightness/HotKey.swift \
  Tests/HotKeyChecks/main.swift

exit "$status"
