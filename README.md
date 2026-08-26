# Monitor Brightness Sync

A macOS menu-bar agent that mirrors the **built-in display's brightness onto external monitors** over DDC/CI, so the Mac's brightness keys control every screen at once and they stay in sync. Each external monitor has its own calibration curve, because Apple's brightness scale is perceptual (non-linear) and panels differ.

> Apple Silicon only. Uses several private APIs (see [Caveats](#caveats)) — not App Store eligible.

## Features

- **One set of brightness keys** — the Mac's brightness keys drive the built-in and all externals together, kept in sync ~7×/sec.
- **Per-monitor calibration** — a multi-point curve per display (saved as a profile), so brightness *matches* across panels, not just tracks.
- **Per-monitor control** — enable/disable each external, or set its brightness manually.
- **Sub-floor dimming** — dim an external below its hardware minimum (in software) to match the Mac at low brightness, with an opt-in "all the way to black".
- **Software dimming for non-DDC monitors** — displays with no DDC/CI channel (DisplayLink docks, some hubs, certain TVs) follow the built-in via the gamma table, with their own calibration curve. Software dimming only goes *down* from the panel's own brightness setting, so set the monitor's own buttons to maximum and the app's 100% becomes that. AirPlay and Sidecar displays are detected too, but enroll switched off so a session doesn't start dimming a TV.
- **Clamshell / external-only mode** — with the lid closed, the brightness keys drive the external directly, with a lookalike on-screen overlay.
- **Custom global hotkeys** — optional, user-recordable shortcuts that replace the brightness keys (handy on a keyboard without them).
- **Reconcile** — notices when you change brightness on the monitor's own buttons and keeps the app's state honest.
- **Accessibility** — VoiceOver labels throughout, plus spoken brightness/hint announcements.
- **Niceties** — first-run onboarding, launch at login, and a tabbed settings window; lives quietly in the menu bar (no window pop on login).

## Requirements

- Apple Silicon Mac, macOS 13+
- **Xcode Command Line Tools** (full Xcode not required) — the app is built with Swift Package Manager and wrapped into an `.app` bundle by `build.sh`.

## Build & run

```sh
./build.sh                              # compile (release), assemble + sign the .app
open "build/Monitor Brightness Sync.app"
```

### Code signing & permissions

macOS keys Accessibility / Input Monitoring grants to the app's **code-signing
identity**. An ad-hoc signature has none, so the grant is dropped on every build
and "Use brightness keys with lid closed" never sticks. Create a stable
self-signed identity once and `build.sh` will sign with it automatically
(otherwise it falls back to ad-hoc):

```sh
./tools/make-signing-cert.sh    # one-time
```

On the first build after creating the cert, macOS may prompt **"codesign wants to
use the key …"** — click **Always Allow** (once) so future builds don't block.

If the permission still won't take after enabling it, clear any stale grant and
relaunch: `tccutil reset Accessibility com.rick.syncbrightness`.

> Custom **global hotkeys** use Carbon and work system-wide *without* Accessibility.
> Only the lid-closed brightness-key tap needs the Accessibility grant.

Faster inner loop while developing:

```sh
swift build                             # debug build
./run-tests.sh                          # framework-free unit checks (no Xcode needed)
```

> Tests use a tiny framework-free harness because XCTest/swift-testing ship only
> with full Xcode, and this project targets a Command Line Tools setup. Each
> driver is compiled with the real source it checks; `run-tests.sh` runs them all
> and aggregates the result. With Xcode installed you can add a normal
> `.testTarget` if you prefer.

### Diagnostics (no UI)

```sh
BIN="$(swift build -c release --show-bin-path)/SyncBrightness"
SYNCBRIGHTNESS_DIAG=1     "$BIN"        # read-only: list displays, built-in %, DDC read
SYNCBRIGHTNESS_DIAG=write "$BIN"        # also writes ~50% (changes the monitor's brightness)
```

## How it works

The Mac's brightness keys (F1/F2) natively drive only the **built-in** display. This app polls the built-in brightness ~7×/sec and writes the matching value (through each monitor's calibration curve) over DDC/CI, so the externals track it. No key interception is needed for the normal case.

- **Lid open:** pure poll-and-mirror. The brightness keys hit the built-in; we mirror.
- **Clamshell (no built-in):** there's nothing to mirror, so we tap the brightness keys (and/or honor the custom hotkeys) and drive the external directly, showing an on-screen overlay.
- **Custom hotkeys** behave like the brightness keys everywhere: lid open they set the built-in (via DisplayServices) so the mirror follows; clamshell they drive the external.
- **Non-DDC displays** can't take a brightness write, so we follow the built-in via the CoreGraphics gamma table instead.
- **Reconcile:** when we're not actively driving a display, an occasional DDC read keeps our state in step with the monitor's own buttons.

Brightness can't be read reliably on Apple Silicon's built-in display via public APIs, and external DDC is enumerated through a private `IOAVService`, hence the private-API usage.

## Architecture

```
Sources/
  CDDC/                       C shim declaring private IOKit IOAVService symbols (linked from IOKit)
  SyncBrightness/
    main.swift                Entry point. SYNCBRIGHTNESS_DIAG hook, then NSApplication (accessory)
    AppDelegate.swift         Menu-bar item + menu, windows, settings persistence, wake observers,
                              media-key + global-hotkey wiring, login-launch detection, orchestration
    SyncController.swift      CORE. Serial-queue poll loop; per-display curves; sub-floor + non-DDC
                              gamma; manual/clamshell coalescing; reconcile reads; calibration; wake re-apply
    DDC.swift                 DDC/CI over IOAVService: enumeration + identity, CGDirectDisplayID resolution,
                              low-level write/read framing, ExternalDisplay (incl. gamma-follow state)
    BuiltinBrightness.swift   Reads/sets any display's brightness via dlsym'd DisplayServices
    BrightnessCurve.swift     Multi-point calibration curve + piecewise-linear interpolation (pure, tested)
    DisplayResolver.swift     Claims CoreGraphics displays for DDC monitors; the rest are software-dimmed (pure, tested)
    GammaDimmer.swift         Software dimming via CoreGraphics gamma tables
    MediaKeyTap.swift         CGEventTap on the brightness keys (clamshell / external-only mode)
    HotKey.swift              Carbon global hotkeys + KeyCombo model (modifier mapping is unit-tested)
    KeyRecorder.swift         Click-to-record keyboard-shortcut control
    BrightnessHUD.swift       Version-aware brightness overlay (Liquid Glass pill on macOS 26+, classic bezel)
    MessageHUD.swift          Transient hint overlay (e.g. "turn on a monitor")
    OverlayMaterial.swift     Shared overlay material + VoiceOver announcement helper
    OnboardingWindowController.swift   First-run welcome
    ControlWindowController.swift      Tabbed settings window (Displays / Dimming / Shortcuts / General)
    CalibrationWindowController.swift  Calibration window with per-monitor picker
    Diagnostics.swift         Env-var hardware probe
Tests/
  CurveChecks/                BrightnessCurve interpolation/persistence checks
  HotKeyChecks/               KeyCombo modifier-mapping / defaults / Codable checks
  ResolverChecks/             DisplayResolver claim-cascade and identity-key checks
tools/make-icon.swift         Generates Resources/AppIcon.icns
tools/make-signing-cert.sh    Creates a stable self-signed signing identity (one-time)
build.sh                      Compile + bundle + sign (stable identity if present, else ad-hoc)
run-tests.sh                  Compile + run the unit checks (CLT only, no Xcode)
```

### Threading model

`SyncController` owns a single serial `DispatchQueue`. **All** mutable sync state and **all** DDC/gamma calls happen on that queue. UI callbacks (`onUpdate`, `onMonitors`, `onExternalChangedExternally`) are dispatched to the main queue. When adding logic to the controller, keep it on `queue` and only cross to main for UI.

### UI surfaces

There are two: the **menu-bar dropdown** (a quick, always-synced subset of toggles plus *Open Settings…*) and the **control window** (the full settings, organized into tabs). They're driven from the same state via `pushToggleStates()` / `renderStatus()`, so they never disagree.

### Adding a feature — the common pattern

1. **Sync behavior** lives in `SyncController`. Add a `setX(...)` method that does `queue.async { ... }`, and force a re-apply with `lastAppliedFraction = -1` if it should take effect immediately.
2. **A user-facing setting** is wired in `AppDelegate`: add a persisted value (a `UserDefaults` key) and a central `setX(_:)` that updates the model and calls `pushToggleStates()`. Surface it in the control window (`ControlWindowController`), and add the common ones to the menu too; both read the same state.
3. **Per-monitor state** flows out via `MonitorState` from `SyncController.reportMonitors()`.
4. Prefer adding pure logic (like `BrightnessCurve` or `KeyCombo`) that can be unit-tested.

## Caveats

- **Private APIs:** `IOAVService*` (IOKit), `DisplayServicesGet/SetBrightness` (DisplayServices, dlsym'd), and CoreGraphics gamma. Same approach as MonitorControl/Lunar; stable in practice, but not App Store eligible.
- **Apple Silicon only.** The Intel DDC path (`IOFramebufferI2C…`) is not implemented.
- **Accessibility permission** is required for "Use brightness keys with lid closed" (the event tap), and it only *persists* with a stable signing identity (see [Code signing & permissions](#code-signing--permissions)). Custom global hotkeys don't need it.
- **Be gentle with DDC.** Some monitors (e.g. those that fail DDC *reads*) have flaky controllers; flooding them with traffic can wedge the link. Writes are single-cycle, low-retry, and coalesced, and reconcile reads are infrequent — keep it that way.
- **Software dimming and Night Shift.** Sub-floor dimming and the non-DDC fallback both adjust the display's gamma/color table, so they can interact with Night Shift, True Tone, or f.lux at very low brightness. Dimming is clamped to a small visible floor by default ("Allow dimming all the way to black" removes the clamp); gamma is restored on quit, and `CGDisplayRestoreColorSyncSettings()` runs on launch to self-heal a force-killed run.
- **Software dimming can't brighten.** With no DDC channel there's no backlight to command — the gamma table only scales luminance downward. "Allow dimming all the way to black" is also ignored for these displays: there's no backlight to fall back on, so removing the clamp would leave a screen too dark to read the control that undoes it.
- **DisplayLink still needs its driver.** This app controls brightness on a DisplayLink monitor; it does not replace DisplayLink Manager, which is what puts pixels on the screen. There is no way around that on macOS.

## Reference

DDC/CI framing for Apple Silicon is based on MonitorControl's `Arm64DDC` (the operand count doubles as the DDC opcode; source address `0x51` is passed as the I2C offset; chip address `0x37`).
