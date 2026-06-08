# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS menu-bar agent (Apple Silicon, macOS 13+) that mirrors the built-in display's
brightness onto external monitors over DDC/CI, with a per-monitor calibration curve.
Built with Swift Package Manager + Command Line Tools (full Xcode not required) and
wrapped into an `.app` by `build.sh`. Uses several private APIs, so it is not App Store
eligible. See `README.md` for the full feature/caveat list.

## Commands

```sh
swift build                  # fast debug build (inner loop)
./build.sh                   # release build + assemble/sign the .app bundle
open "build/Monitor Brightness Sync.app"
./run-tests.sh               # run all unit checks (no Xcode needed)
```

Run a single test driver directly (this is what `run-tests.sh` does under the hood —
each driver is compiled together with the real source it exercises):

```sh
swiftc Sources/SyncBrightness/BrightnessCurve.swift Tests/CurveChecks/main.swift -o /tmp/t && /tmp/t
swiftc -framework Cocoa -framework Carbon Sources/SyncBrightness/HotKey.swift Tests/HotKeyChecks/main.swift -o /tmp/t && /tmp/t
```

Headless hardware probe (no UI):

```sh
BIN="$(swift build -c release --show-bin-path)/SyncBrightness"
SYNCBRIGHTNESS_DIAG=1     "$BIN"   # read-only: list displays, built-in %, DDC read
SYNCBRIGHTNESS_DIAG=write "$BIN"   # also writes ~50% (changes the monitor)
```

### Tests are framework-free by necessity

XCTest/swift-testing ship only with full Xcode; this project targets a CLT-only setup.
So tests are a hand-rolled harness — keep new tests in that style and prefer extracting
**pure** logic (like `BrightnessCurve`, `KeyCombo`) that can be checked without hardware.

## Architecture (the parts that need multiple files to understand)

- **`SyncController.swift`** is the core. It polls the built-in brightness ~7×/sec and
  writes the matching value (through each monitor's curve) over DDC, so externals track
  the brightness keys with no key interception in the normal (lid-open) case.
- **`DDC.swift`** — DDC/CI over the private `IOAVService` (enumeration, identity,
  `CGDirectDisplayID` resolution, write/read framing, `ExternalDisplay` state).
- **`BuiltinBrightness.swift`** — reads/sets brightness via `dlsym`'d DisplayServices.
- **`AppDelegate.swift`** — menu-bar item, windows, `UserDefaults` persistence, wake
  observers, media-key/hotkey wiring, login-launch detection; the orchestration layer.

### Threading invariant (critical)

`SyncController` owns one serial `DispatchQueue`. **All** mutable sync state and **all**
DDC/gamma calls happen on that queue. UI callbacks (`onUpdate`, `onMonitors`,
`onExternalChangedExternally`) are dispatched to main. When adding controller logic,
wrap it in `queue.async { ... }`; only cross to main for UI. To force an immediate
re-apply, set `lastAppliedFraction = -1`.

### Two UI surfaces, one state

The menu-bar dropdown and the tabbed control window (`ControlWindowController`) are both
driven from the same state via `pushToggleStates()` / `renderStatus()` so they never
disagree. Per-monitor state flows out via `MonitorState` from `reportMonitors()`.

### Adding a setting — the pattern

1. Sync behavior → a `setX(...)` on `SyncController` that does `queue.async { ... }`.
2. User-facing setting → in `AppDelegate`: a `UserDefaults` key + a central `setX(_:)`
   that updates the model and calls `pushToggleStates()`; surface it in the control
   window (and the menu for common ones). Both read the same state.

## Things to be careful about

- **Be gentle with DDC.** Some monitors have flaky controllers; flooding them can wedge
  the link. Writes are single-cycle, low-retry, and coalesced; reconcile reads are
  infrequent. Keep it that way.
- **Code signing & TCC.** macOS keys Accessibility/Input-Monitoring grants to the
  signing identity. Ad-hoc signatures drop the grant every build, so the lid-closed
  brightness-key tap won't persist. Run `./tools/make-signing-cert.sh` once for a stable
  identity that `build.sh` picks up automatically (override via `SIGN_IDENTITY`). Custom
  Carbon global hotkeys work system-wide without Accessibility.
- **Gamma side effects.** Sub-floor dimming and the non-DDC fallback adjust the display
  gamma table, which can interact with Night Shift/True Tone/f.lux at low brightness.
  Gamma is restored on quit and `CGDisplayRestoreColorSyncSettings()` runs on launch to
  self-heal a force-killed run.
- **Apple Silicon only.** The Intel DDC path is not implemented.
