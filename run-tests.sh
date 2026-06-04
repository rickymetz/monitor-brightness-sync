#!/bin/bash
# Framework-free unit checks that run with only the Command Line Tools (no Xcode
# needed). Compiles the real source files together with the check drivers.
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp -d)/curve-checks"
swiftc Sources/SyncBrightness/BrightnessCurve.swift Tests/CurveChecks/main.swift -o "$OUT"
"$OUT"
