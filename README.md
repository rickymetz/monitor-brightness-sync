# Monitor Brightness Sync

A macOS menu-bar agent that mirrors the **built-in display's brightness onto external monitors** over DDC/CI, so the Mac's brightness keys control every screen at once and they stay in sync. Each external monitor has its own calibration curve, because Apple's brightness scale is perceptual (non-linear) and panels differ.

> Apple Silicon only. Uses several private APIs (see [Caveats](#caveats)) — not App Store eligible.

## Requirements

- Apple Silicon Mac, macOS 13+
- **Xcode Command Line Tools** (full Xcode not required) — the app is built with Swift Package Manager and wrapped into an `.app` bundle by `build.sh`.

## Build & run

```sh
./build.sh                              # compile (release), assemble + ad-hoc sign the .app
open "build/Monitor Brightness Sync.app"
```

### Code signing & permissions

macOS keys Accessibility / Input Monitoring grants to the app's **code-signing
identity**. An ad-hoc signature has none, so the grant is dropped on every build
and "Use brightness keys with lid closed" never sticks. Create a stable
self-signed identity once:

```sh
./tools/make-signing-cert.sh    # one-time; build.sh then signs with it automatically
```

On the first build after creating the cert, macOS may prompt **"codesign wants to
use the key …"** — click **Always Allow** (once) so future builds don't block.

If the permission still won't take after enabling it, clear any stale grant and
relaunch: `tccutil reset Accessibility com.rick.syncbrightness`.

Faster inner loop while developing:

```sh
swift build                             # debug build
./run-tests.sh                          # framework-free unit checks (no Xcode needed)
```

> Tests use a tiny framework-free harness because XCTest/swift-testing ship only
> with full Xcode, and this project targets a Command Line Tools setup. With
> Xcode installed you can add a normal `.testTarget` if you prefer.

### Diagnostics (no UI)

```sh
BIN="$(swift build -c release --show-bin-path)/SyncBrightness"
SYNCBRIGHTNESS_DIAG=1     "$BIN"        # read-only: list displays, built-in %, DDC read
SYNCBRIGHTNESS_DIAG=write "$BIN"        # also writes ~50% (changes the monitor's brightness)
```

## How it works

The Mac's brightness keys (F1/F2) natively drive only the **built-in** display. This app polls the built-in brightness ~7×/sec and writes the matching value to each external over DDC/CI, so the externals track it. No key interception is needed for the normal case — only for clamshell (see `MediaKeyTap`).

Brightness can't be read reliably on Apple Silicon's built-in display via public APIs, and external DDC is enumerated through a private `IOAVService`, hence the private-API usage.

## Architecture

```
Sources/
  CDDC/                       C shim declaring private IOKit IOAVService symbols (linked from IOKit)
  SyncBrightness/
    main.swift                Entry point. SYNCBRIGHTNESS_DIAG hook, then NSApplication (accessory)
    AppDelegate.swift         Menu-bar item, menu, control window, settings persistence,
                              wake observers, media-key wiring, toggle/calibration orchestration
    SyncController.swift       CORE. Serial-queue polling loop; per-display curves; gamma dimming;
                              manual-write coalescing; calibration mode; wake re-apply; monitor reporting
    DDC.swift                 DDC/CI over IOAVService: display enumeration + identity,
                              CGDirectDisplayID resolution, low-level write/read framing, ExternalDisplay
    BuiltinBrightness.swift   Reads built-in brightness via dlsym'd DisplayServices
    BrightnessCurve.swift     Multi-point calibration curve + piecewise-linear interpolation (pure, tested)
    GammaDimmer.swift         Sub-floor dimming via CoreGraphics gamma tables
    MediaKeyTap.swift         CGEventTap on brightness keys (clamshell / external-only mode)
    BrightnessHUD.swift       On-screen brightness overlay for external-only mode
    ControlWindowController.swift     Windowed control panel (mirrors the menu)
    CalibrationWindowController.swift  Calibration window with per-monitor picker
    Diagnostics.swift         Env-var hardware probe
Tests/CurveChecks/            Framework-free unit checks (run via ./run-tests.sh)
tools/make-icon.swift         Generates Resources/AppIcon.icns
tools/make-signing-cert.sh    Creates a stable self-signed signing identity (one-time)
build.sh                      Compile + bundle + ad-hoc sign
run-tests.sh                  Compile + run the unit checks (CLT only, no Xcode)
```

### Threading model

`SyncController` owns a single serial `DispatchQueue`. **All** mutable sync state and **all** DDC/gamma calls happen on that queue. UI callbacks (`onUpdate`, `onMonitors`) are dispatched to the main queue. When adding logic to the controller, keep it on `queue` and only cross to main for UI.

### Adding a feature — the common pattern

1. **Sync behavior** lives in `SyncController`. Add a `setX(...)` method that does `queue.async { ... }`, and force a re-apply with `lastAppliedFraction = -1` if it should take effect immediately.
2. **A user-facing toggle** is wired in `AppDelegate`: add a persisted setting (a `UserDefaults` key), a central `setX(_:)` that updates the model + calls `pushToggleStates()`, and expose it in **both** the menu (`buildStatusItem`) and the control window (`ControlWindowController`) for parity.
3. **Per-monitor state** flows out via `MonitorState` from `SyncController.reportMonitors()`.
4. Prefer adding pure logic (like `BrightnessCurve`) that can be unit-tested.

## Caveats

- **Private APIs:** `IOAVService*` (IOKit), `DisplayServicesGetBrightness` (DisplayServices, dlsym'd), and CoreGraphics gamma. Same approach as MonitorControl/Lunar; stable in practice, but not App Store eligible.
- **Apple Silicon only.** The Intel DDC path (`IOFramebufferI2C…`) is not implemented.
- **Accessibility permission** is required for "Use brightness keys with lid closed" (the event tap), and it only *persists* with a stable signing identity (see [Code signing & permissions](#code-signing--permissions)).
- **Be gentle with DDC.** Some monitors (e.g. those that fail DDC *reads*) have flaky controllers; flooding them with writes can wedge the link. Writes are deliberately single-cycle, low-retry, and coalesced — keep it that way.
- **Gamma safety.** Dimming is clamped to a small visible floor by default (the "Dim all the way to black" option removes the clamp for true blackout); gamma is restored on quit, and `CGDisplayRestoreColorSyncSettings()` runs on launch to self-heal a force-killed run.

## Reference

DDC/CI framing for Apple Silicon is based on MonitorControl's `Arm64DDC` (the operand count doubles as the DDC opcode; source address `0x51` is passed as the I2C offset; chip address `0x37`).
