# Software-dimmed displays (non-DDC monitors)

Date: 2026-08-25
Status: design, awaiting implementation plan

## Problem

A DisplayLink-attached monitor is invisible to the app. `DDC.externalDisplays()`
(`Sources/SyncBrightness/DDC.swift:134`) builds its entire display list by walking the
IORegistry for `DCPAVServiceProxy` entries with `Location == "External"`. A DisplayLink
display is a virtual framebuffer with no `DCPAVServiceProxy` and no `IOAVService`, so it
is never enumerated. Diagnostics on the affected machine report
`External displays over DDC/CI: 0` while two displays are online.

The README claims non-DDC monitors "still follow the built-in via the gamma table". That
is false for this topology. The gamma fallback in `SyncController.setLevel` only runs for
a display that was *already enumerated* and then refused a DDC write. A display that was
never enumerated never reaches that code.

Confirmed on the affected hardware:

- Dock is a genuine DisplayLink device (USB `0x17e9`/`0x6000`, "DL-Dock").
- The external display has a `CGDirectDisplayID` and a full gamma table
  (`CGDisplayGammaTableCapacity` = 1024) but no `IOAVService`.
- `CGSetDisplayTransferByFormula` on that display **visibly changes the panel**, verified
  by a ramp test with the user watching. Gamma is a working dimming path here.

## Non-goals

- **Removing the DisplayLink Manager dependency.** DisplayLink is a USB graphics chip;
  frames are compressed and shipped over USB by the proprietary driver. No open driver
  exists on macOS, and DisplayLink Manager exposes no DDC passthrough. The video pipeline
  cannot be replaced from this app. The user has decided against recabling, so the
  dependency stays. This work only makes brightness follow.
- **Brightening.** Software dimming scales luminance downward from whatever the panel's
  own hardware brightness is set to. The app's 100% is the panel's own setting.
- **Chasing specific DisplayLink defects.** The user reports general flakiness with no
  reproducible symptom. Display add/remove is already handled (see below); nothing further
  is added speculatively.

## Approach

Chosen from three options:

- **A (chosen)** — make `ExternalDisplay.service` optional. A display with no
  `IOAVService` is permanently in the gamma-follow state that `ExternalDisplay` already
  models via `followsViaGamma` / `markGammaFollow(level:)`. All downstream machinery —
  curve, enable/disable, manual slider, HUD, menu — works unchanged.
- **B** — a separate `GammaDisplay` type and a parallel list. Rejected: every UI surface
  and every toggle would iterate two lists, duplicating plumbing in
  `ControlWindowController` (525 lines) and `AppDelegate` (621 lines) for no behavioral
  gain.
- **C** — a `BrightnessTransport` protocol. Rejected as ceremony at two implementations;
  it would rewrite most of `DDC.swift` to express what one optional expresses.

## Already handled — do not rebuild

`SyncController.registerReconfigurationCallback` (`SyncController.swift:296`) already
registers `CGDisplayRegisterReconfigurationCallback` for `.addFlag` / `.removeFlag` /
`.setMainFlag` and rescans on each. DisplayLink dropping and reattaching therefore
re-enumerates and re-applies with no new work. `start()` also retries the scan at 1.5s,
4.0s and 8.0s for displays that enumerate late.

## Design

### Enumeration

`ExternalDisplay.service` becomes `IOAVService?`, with a derived flag:

```swift
var isSoftwareOnly: Bool { service == nil }
```

`DDC.externalDisplays()` keeps its IORegistry walk unchanged, then runs a second pass over
online non-builtin `CGDirectDisplayID`s that no DDC display claimed, wrapping each as an
`ExternalDisplay` with `service: nil` and `cgDisplayID` pre-set.

**Enrollment filter.** The unclaimed set is not only DisplayLink monitors — it also
includes AirPlay targets, Sidecar iPads, and third-party virtual displays. Enrolling those
enabled would gamma-dim an Apple TV to match the laptop as soon as an AirPlay session
starts.

Rule: a software-only display reporting Apple's vendor number `0x610` is enrolled
**default-disabled**; every other vendor enrolls enabled. Either way the display is listed
in the UI, so a default-disabled one is one checkbox away from working.

This vendor test is a heuristic, not a verified property of every AirPlay and Sidecar
target — it is unverified on this hardware and it is the reason the display stays visible
and toggleable rather than being hidden. It is chosen because it fails safe in both
directions: a misclassified AirPlay target dims nothing until asked, and a misclassified
real monitor is one checkbox from working.

**Persisting the default.** `disabledIDs` records displays the user has switched off; it
cannot distinguish "never seen" from "seen and left enabled". Applying a default-disabled
rule therefore needs a companion `seenDisplayIDs` set persisted in `UserDefaults`. On
enumeration, a software-only display whose id is absent from `seenDisplayIDs` is added to
it, and additionally added to `disabledIDs` when the vendor test says default-disabled.
A display already in `seenDisplayIDs` keeps whatever the user chose.

**Accepted transient.** The default is applied on the main thread from the monitors
callback, so it takes one round trip back to the sync queue — one to three ticks, roughly
150–450 ms — during which a newly-appeared AirPlay display is still enrolled enabled and
may visibly dim for a blink. It self-corrects on the next tick. Not worth engineering
around.

### Identity

Profile key is `sw-<vendor>-<model>-<serial>` from `CGDisplayVendorNumber`,
`CGDisplayModelNumber`, `CGDisplaySerialNumber`. On the affected machine that is
`sw-10635-10049-244`. Rationale:

- The `sw-` prefix cannot collide with a DDC key, which is
  `MANUFACTURER-ProductName-serial` (`DDC.swift:307`).
- All three components come from EDID and survive a replug, unlike `CGDirectDisplayID`.

**Fallback:** when vendor, model and serial are all zero, the key appends the display name
and `CGDisplayUnitNumber` so two such panels do not share one calibration profile.

### Display names

`NSScreen.localizedName` yields "E27FP1K"; the IORegistry path yields `product=?` for this
display, which would surface as "External display".

`NSScreen` wants the main thread, and `rescanDisplays()` runs on `SyncController.queue`.
`DispatchQueue.main.sync` from that queue can deadlock, because `shutdown()` calls
`queue.sync` from main. Therefore: `AppDelegate` owns a `[CGDirectDisplayID: String]` name
cache, refreshed on main from `NSApplication.didChangeScreenParametersNotification`, and
passes it into enumeration. The cache is populated on main **before** `sync.start()` so the
first scan is not cold; the reconfiguration callback covers later changes. Enumeration
falls back to "External display" if a name is missing.

### Claim ordering (bug fix)

`DDC.resolveDisplayIDs` (`DDC.swift:173`) currently matches DDC displays to CG IDs by EDID
serial, then hands out leftovers positionally. With a DisplayLink display present, that
positional fallback can bind the DisplayLink display's CG ID to a DDC monitor and gamma-dim
the wrong screen. Harmless today (zero DDC externals on this machine) but wrong as soon as a
DDC monitor is added.

A software-only display cannot "claim first", because which displays are
software-only is only knowable *after* the DDC displays have taken theirs. The rule is
therefore a claim cascade, strongest signal first, with the residue falling out as
software-only:

1. **EDID serial** — each DDC display takes the CG display whose serial matches. Skipped
   when the serial is 0 ("not reported").
2. **Product ID** — each still-unresolved DDC display takes the CG display whose model
   number matches, but only when exactly one candidate matches. This requires reading
   `ProductID` from `ProductAttributes`, which `identity(of:)` does not currently do.
3. **Positional** — whatever DDC displays remain take what is left, in connection order.
4. **Residue** — every CG display no DDC display claimed is software-only.

**Known limitation, accepted.** Step 3 is a guess, exactly as today. A DDC monitor that
reports neither a serial nor a product ID, sharing a machine with a software-only display,
can still bind to the wrong CG ID. Steps 1 and 2 make that vanishingly rare — the affected
DisplayLink display reports both (`model=10049`, `serial=244`) — and step 4 is the part
that actually matters, since leftovers are currently discarded rather than driven. This is
documented rather than solved because there is no positive way to identify a virtual
display from CoreGraphics alone.

### Brightness mapping

For a software-only display the gamma factor is the calibration curve's output:

```
level = max(minGamma, display.curve.external(for: builtin))
```

where `minGamma` is `GammaDimmer.minFactor` (0.15).

**"Allow dimming all the way to black" applies to software-only displays too.**
Superseded 2026-09-01: the original design held the 0.15 floor unconditionally for these
displays, reasoning that a fully black gamma-only screen is also the screen showing the
control that would undo it. In practice that made the setting a no-op on exactly the
displays a user most wants it for, and the reasoning overweighted the risk — the dimming
is user-initiated and the brightness keys raise it again. The floor is now the default,
and the setting lifts it to 0.

Where black lands is a property of the calibration curve, not the clamp: the display goes
fully dark at whatever built-in level the curve maps to 0, which for `BrightnessCurve.default`
is `zeroBuiltin` (0.15) and below.

**Behavior change to an existing path.** The refused-DDC-write branch
(`SyncController.swift:262-269`) currently passes `dimInput` — the *raw* built-in level —
to `gamma.set`, discarding the display's calibration curve. Both branches now use the
curve. This means a flaky-DDC monitor that falls back to gamma starts respecting its
calibration where it previously ignored it. This is intentional and consistent: one code
path, one behavior.

**Sub-floor dimming does not apply** to software-only displays. There is no hardware floor
to go under; the entire range is already gamma.

### Calibration

The `calibrating` branch in `tick()` (`SyncController.swift:224`) sets
`gamma.set(factor: 1)` and then calls `setBrightness` — deliberately pure DDC. On a
software-only display this pins gamma to full and writes to nothing, so the calibration
slider would move with no visible effect. A software-only branch drives gamma to
`manualExternal` directly. Without this, the per-monitor curve is uncalibratable.

### Other call sites

- `flushPendingManual` and `flushPendingExternalOnly` (clamshell) route through the same
  `setLevel` seam and get the same software-only branch.
- `ExternalDisplay.refreshMaxBrightness()` returns early for software-only displays — no
  bus to probe.
- `reconcileExternalLevels()` skips them — no DDC to read and no monitor buttons to
  reconcile against.
- `setBrightness(ramp:)` is DDC-only. The software branch applies directly on wake;
  gamma needs no stepped ramping.

### Error handling

`reportMonitors` reports `healthy: cgDisplayID != nil` for software-only displays.

Existing gamma safety nets cover the rest and need no change: `shutdown()` calls
`gamma.reset()`; `AppDelegate.swift:86` self-heals a force-killed run via
`CGDisplayRestoreColorSyncSettings()`; `setDisabled` (`SyncController.swift:64`) already
restores gamma to 1 so a disabled monitor is never left dimmed.

### UI

`MonitorState` gains `softwareDimmed: Bool`. `ControlWindowController` renders a badge on
that row indicating software dimming. The calibration picker treats the display like any
other monitor. No new panes.

## Testing

Pure logic, unit-tested in the existing CLT-only harness (`run-tests.sh`):

- **New `ResolverChecks` suite** over the extracted claim-ordering rule, as a pure function
  of `(ddcDisplays, cgIDs)`:
  - zero DDC externals plus one software-only display (the affected setup)
  - mixed DDC and software-only, with the software display listed **first** in
    connection order — the adversarial ordering that mis-binds under today's code
  - product-ID tiebreak when the EDID serial is 0
  - two identical DDC monitors distinguished by EDID serial
  - identity fallback when vendor/model/serial are all zero
- **Enrollment filter** — Apple-vendor displays default to disabled, others to enabled;
  a display already in `seenDisplayIDs` is left at the user's choice rather than reset to
  the default.
- **Blackout clamp** — a software-only display stays at or above `GammaDimmer.minFactor` even
  by default, and reaches 0 when "allow dimming all the way to black" is enabled.

Hardware paths (gamma writes, DDC) cannot be unit-tested. `Diagnostics` (`SYNCBRIGHTNESS_DIAG=1`)
is extended to list software-only displays alongside DDC ones, with their resolved
identity key, name and CG display id.

## Files touched

| File | Change |
| --- | --- |
| `Sources/SyncBrightness/DisplayResolver.swift` | **new** — pure claim cascade and identity keys, no IOKit |
| `Sources/SyncBrightness/DDC.swift` | optional `service`, `isSoftwareOnly`, `productID`, second enumeration pass, calls the resolver |
| `Sources/SyncBrightness/SyncController.swift` | software-only branches in `setLevel`, `tick` calibration, reconcile/refresh skips, curve on both gamma paths |
| `Sources/SyncBrightness/AppDelegate.swift` | display-name cache on main, populated before `sync.start()`; persisted `seenDisplayIDs` set |
| `Sources/SyncBrightness/ControlWindowController.swift` | software-dimmed badge |
| `Sources/SyncBrightness/Diagnostics.swift` | list software-only displays |
| `Tests/ResolverChecks/` | new suite |
| `run-tests.sh` | register the new suite |
| `README.md` | correct the non-DDC claim; document the ceiling and the AirPlay default |
