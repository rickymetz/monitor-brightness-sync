> **⚠️ SUPERSEDED (2026-06-08).** Tasks 1–2 (value types, `DisplayColorState`) were
> completed and are reused. Task 3 onward (web server, HTML page, within-photo matcher)
> is abandoned — see `../specs/2026-06-08-native-color-sync-design.md`. A new plan will
> be written for the native iOS architecture.

# Phone-Camera Color Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user match colors across displays by photographing each screen with their phone — the app serves a local web page (QR-linked), the phone uploads a photo of an on-screen patch card per display, and the app derives + applies a per-display gamma correction.

**Architecture:** Five phases, foundation-first. (1) Refactor `GammaDimmer` into `DisplayColorState` that composes a per-display color correction with the existing dim factor into one gamma write. (2) Pure `ColorMatcher` that turns photographed patch samples into per-display corrections (camera gain cancels via within-photo ratios). (3) `PatchCardAnalyzer` that locates + samples the patch card in a photo. (4) `CalibrationServer` (Network.framework) + QR + phone page. (5) Patch-card window, the Color Sync UI flow, persistence, and wiring into `SyncController`/`AppDelegate`.

**Tech Stack:** Swift + SwiftPM, Cocoa, CoreGraphics (gamma), Network.framework (`NWListener` HTTP), CoreImage (`CIQRCodeGenerator`, pixel access), Accelerate (sampling). No third-party dependencies. Framework-free tests via `run-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-06-08-phone-camera-color-sync-design.md`

---

## File structure

| File | Responsibility | Phase |
|---|---|---|
| `Sources/SyncBrightness/ColorCorrection.swift` | `ColorCorrection` value type (per-channel gains + gamma), `RGB`, `PatchSamples`, the pure transfer-formula helper. Codable for persistence. | 1 |
| `Sources/SyncBrightness/DisplayColorState.swift` | Replaces `GammaDimmer.swift`. Holds dim factor + correction per display; composes into one `CGSetDisplayTransferByFormula`. Keeps `set(_:factor:)` + `reset()`. | 1 |
| `Sources/SyncBrightness/ColorMatcher.swift` | Pure: `[DisplayMeasurement]` + referenceID → `[String: ColorCorrection]`. | 2 |
| `Sources/SyncBrightness/PatchCardAnalyzer.swift` | Photo (CGImage) → `PatchSamples` via corner-fiducial detection + homography sampling. | 3 |
| `Sources/SyncBrightness/CalibrationServer.swift` | `NWListener` HTTP server: serves phone page, accepts uploads, exposes poll state. Token-gated, session-scoped. | 4 |
| `Sources/SyncBrightness/ColorSyncPage.swift` | The inline HTML/JS/CSS string for the phone page. | 4 |
| `Sources/SyncBrightness/PatchCardWindow.swift` | Fullscreen window rendering the patch card on a chosen display. | 5 |
| `Sources/SyncBrightness/ColorSyncWindowController.swift` | Mac-side flow: QR, live status, final before/after + fine-tune sliders, Save. | 5 |
| `Tests/ColorChecks/main.swift` | Framework-free checks for `ColorCorrection`, `DisplayColorState`, `ColorMatcher`, `PatchCardAnalyzer`. | 1–3 |

Integration touch points: `SyncController.swift` (owns `DisplayColorState`, applies corrections on its serial queue, re-applies on wake/reconnect), `AppDelegate.swift` (persist `[String: ColorCorrection]`, open the Color Sync window), `ControlWindowController.swift` (a "Color Sync (beta)" button), `run-tests.sh` (register the new driver), `Package.swift` (link CoreImage/Vision if needed — they come with the linked frameworks; confirm).

---

## Phase 1 — `ColorCorrection` + `DisplayColorState` refactor

### Task 1: `ColorCorrection`, `RGB`, `PatchSamples` value types

**Files:**
- Create: `Sources/SyncBrightness/ColorCorrection.swift`
- Test: `Tests/ColorChecks/main.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ColorChecks/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
  if !cond { print("FAIL: \(msg)"); failures += 1 } else { print("ok: \(msg)") }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

// ColorCorrection.identity is a no-op
let id = ColorCorrection.identity
check(id.redGain == 1 && id.greenGain == 1 && id.blueGain == 1 && id.gamma == 1, "identity is unit")

// Codable round-trips
let c = ColorCorrection(redGain: 0.9, greenGain: 1.0, blueGain: 0.8, gamma: 1.0)
let data = try! JSONEncoder().encode(c)
let back = try! JSONDecoder().decode(ColorCorrection.self, from: data)
check(back == c, "ColorCorrection codable round-trip")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: compile error — `ColorCorrection` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SyncBrightness/ColorCorrection.swift`:

```swift
import Foundation

/// A linear RGB triple in 0...1 (measured camera values or display patch colors).
struct RGB: Equatable, Codable {
  var r: Double
  var g: Double
  var b: Double
}

/// Per-channel correction applied to a display's gamma table. Gains are output
/// multipliers in 0...1 (we can only attenuate a channel, not exceed native).
struct ColorCorrection: Codable, Equatable {
  var redGain: Double
  var greenGain: Double
  var blueGain: Double
  var gamma: Double

  static let identity = ColorCorrection(redGain: 1, greenGain: 1, blueGain: 1, gamma: 1)
}

/// Median patch colors sampled from one photo of the patch card on one display.
struct PatchSamples: Equatable {
  var white: RGB
  var gray50: RGB
  var gray25: RGB
  var red: RGB
  var green: RGB
  var blue: RGB
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncBrightness/ColorCorrection.swift Tests/ColorChecks/main.swift
git commit -m "feat: ColorCorrection / RGB / PatchSamples value types"
```

---

### Task 2: `DisplayColorState` — compose correction with dim factor

Replaces `GammaDimmer`. Must keep `set(_:factor:)` and `reset()` so `SyncController`'s existing call sites are unchanged, and produce **byte-identical** output to today's `GammaDimmer` when correction is identity.

**Files:**
- Create: `Sources/SyncBrightness/DisplayColorState.swift`
- Delete: `Sources/SyncBrightness/GammaDimmer.swift`
- Test: `Tests/ColorChecks/main.swift` (extend)

- [ ] **Step 1: Write the failing test** — append before the summary print in `Tests/ColorChecks/main.swift`:

```swift
// Pure transfer formula: dim-only matches the old GammaDimmer formula (0, f, 1) per channel.
do {
  let f = DisplayColorState.formula(dim: 0.5, correction: .identity)
  check(f.red == Channel(min: 0, max: 0.5, gamma: 1), "dim-only red == (0,0.5,1)")
  check(f.green == Channel(min: 0, max: 0.5, gamma: 1), "dim-only green == (0,0.5,1)")
  check(f.blue == Channel(min: 0, max: 0.5, gamma: 1), "dim-only blue == (0,0.5,1)")
}
// No dim, no correction => no-op (0,1,1).
do {
  let f = DisplayColorState.formula(dim: 1, correction: .identity)
  check(f.red == Channel(min: 0, max: 1, gamma: 1), "noop red == (0,1,1)")
}
// Correction attenuates per channel, multiplied by dim.
do {
  let c = ColorCorrection(redGain: 0.8, greenGain: 1.0, blueGain: 0.6, gamma: 1.0)
  let f = DisplayColorState.formula(dim: 0.5, correction: c)
  check(approx(f.red.max, 0.4), "red max == dim*redGain")
  check(approx(f.blue.max, 0.3), "blue max == dim*blueGain")
  check(approx(f.green.max, 0.5), "green max == dim*greenGain")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: compile error — `DisplayColorState` / `Channel` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SyncBrightness/DisplayColorState.swift`:

```swift
import CoreGraphics

/// One channel's CGSetDisplayTransferByFormula triple.
struct Channel: Equatable {
  var min: Float
  var max: Float
  var gamma: Float
}

/// Owns per-display dim factor + color correction, and composes them into a
/// single gamma-table write. Replaces GammaDimmer (same `set(_:factor:)`/`reset()`
/// API so existing SyncController call sites are unchanged). Color correction and
/// sub-floor dimming therefore share one transfer write per display.
final class DisplayColorState {
  private var dims: [CGDirectDisplayID: Double] = [:]
  private var corrections: [CGDirectDisplayID: ColorCorrection] = [:]

  struct Formula: Equatable { var red, green, blue: Channel }

  /// Pure: combine a dim factor (0...1 luminance multiplier) with a correction.
  static func formula(dim: Double, correction c: ColorCorrection) -> Formula {
    func ch(_ gain: Double) -> Channel {
      Channel(min: 0,
              max: Float(max(0, min(1, dim * gain))),
              gamma: Float(max(0.01, c.gamma)))
    }
    return Formula(red: ch(c.redGain), green: ch(c.greenGain), blue: ch(c.blueGain))
  }

  /// Dim a display (1 = no dimming). Preserves GammaDimmer's contract.
  func set(_ id: CGDirectDisplayID?, factor: Double) {
    guard let id else { return }
    dims[id] = max(0, min(1, factor))
    apply(id)
  }

  /// Set the per-display color correction (.identity to clear).
  func setCorrection(_ id: CGDirectDisplayID?, _ c: ColorCorrection) {
    guard let id else { return }
    corrections[id] = c
    apply(id)
  }

  /// Restore color-profile gamma everywhere (call on quit), then re-apply any
  /// non-trivial state. CGDisplayRestoreColorSyncSettings resets every display.
  func reset() {
    CGDisplayRestoreColorSyncSettings()
    for id in Set(dims.keys).union(corrections.keys) { apply(id, restoring: true) }
  }

  private func isTrivial(_ id: CGDirectDisplayID) -> Bool {
    (dims[id] ?? 1) >= 0.999 && (corrections[id] ?? .identity) == .identity
  }

  private func apply(_ id: CGDirectDisplayID, restoring: Bool = false) {
    let dim = dims[id] ?? 1
    let c = corrections[id] ?? .identity
    if isTrivial(id) {
      if !restoring { restoreOthers(except: nil) } // clear this display back to profile
      return
    }
    let f = DisplayColorState.formula(dim: dim, correction: c)
    CGSetDisplayTransferByFormula(id,
      f.red.min, f.red.max, f.red.gamma,
      f.green.min, f.green.max, f.green.gamma,
      f.blue.min, f.blue.max, f.blue.gamma)
  }

  // Clearing one display requires a global restore (no per-display restore API),
  // then re-applying the others that should stay non-trivial.
  private func restoreOthers(except keep: CGDirectDisplayID?) {
    CGDisplayRestoreColorSyncSettings()
    for id in Set(dims.keys).union(corrections.keys) where id != keep && !isTrivial(id) {
      apply(id, restoring: true)
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: `ALL PASS`.

- [ ] **Step 5: Swap `SyncController` to `DisplayColorState` and delete `GammaDimmer`**

In `Sources/SyncBrightness/SyncController.swift:20`, change:

```swift
  private let gamma = GammaDimmer()
```
to:
```swift
  private let gamma = DisplayColorState()
```

All existing `gamma.set(..., factor:)` and `gamma.reset()` calls are unchanged (same API). Then:

```bash
git rm Sources/SyncBrightness/GammaDimmer.swift
```

- [ ] **Step 6: Verify the package still builds and tests pass**

Run: `swift build && ./run-tests.sh`
Expected: build succeeds; existing curve/hotkey checks pass. (Color driver is added to `run-tests.sh` in Task 3 Step 6.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: GammaDimmer -> DisplayColorState composing dim + color correction"
```

---

## Phase 2 — `ColorMatcher` (pure correction math)

The key invariant: an unknown per-channel camera gain `G_d` applied to a whole photo must **cancel**, because we only use within-photo ratios. A display identical to the reference must yield `.identity`.

### Task 3: `ColorMatcher.corrections(...)`

**Files:**
- Create: `Sources/SyncBrightness/ColorMatcher.swift`
- Test: `Tests/ColorChecks/main.swift` (extend)

- [ ] **Step 1: Write the failing test** — append before the summary print:

```swift
// Helper: a synthetic display's emitted patches, then a camera gain applied.
func emit(rScale: Double, gScale: Double, bScale: Double) -> PatchSamples {
  // "emitted" = ideal gray ramp scaled per channel by the display's tint.
  func p(_ level: Double) -> RGB { RGB(r: level * rScale, g: level * gScale, b: level * bScale) }
  return PatchSamples(white: p(1.0), gray50: p(0.5), gray25: p(0.25),
                      red: RGB(r: rScale, g: 0, b: 0),
                      green: RGB(r: 0, g: gScale, b: 0),
                      blue: RGB(r: 0, g: 0, b: bScale))
}
func cameraGain(_ s: PatchSamples, _ gr: Double, _ gg: Double, _ gb: Double) -> PatchSamples {
  func m(_ c: RGB) -> RGB { RGB(r: c.r * gr, g: c.g * gg, b: c.b * gb) }
  return PatchSamples(white: m(s.white), gray50: m(s.gray50), gray25: m(s.gray25),
                      red: m(s.red), green: m(s.green), blue: m(s.blue))
}

// Reference is neutral; target renders grays greenish (g 20% hot).
let refEmit = emit(rScale: 1.0, gScale: 1.0, bScale: 1.0)
let tgtEmit = emit(rScale: 1.0, gScale: 1.2, bScale: 1.0)

// Apply DIFFERENT camera gains to each photo — must not affect the result.
let ref = DisplayMeasurement(displayID: "builtin", samples: cameraGain(refEmit, 0.7, 1.3, 0.9))
let tgt = DisplayMeasurement(displayID: "ext-A", samples: cameraGain(tgtEmit, 1.1, 0.6, 1.4))

let out = ColorMatcher.corrections(measurements: [ref, tgt], referenceID: "builtin")

// Reference maps to identity.
check(out["builtin"] == .identity, "reference correction is identity")

// Target's green is hot => its green gain should be the most attenuated channel.
let tc = out["ext-A"]!
check(tc.greenGain < tc.redGain && tc.greenGain < tc.blueGain, "hot green channel is attenuated most")
check(approx(max(tc.redGain, max(tc.greenGain, tc.blueGain)), 1.0, 1e-6), "gains normalized so max channel == 1")

// Camera-gain independence: re-run with different camera gains, same corrections.
let ref2 = DisplayMeasurement(displayID: "builtin", samples: cameraGain(refEmit, 1.0, 1.0, 1.0))
let tgt2 = DisplayMeasurement(displayID: "ext-A", samples: cameraGain(tgtEmit, 2.0, 0.4, 1.7))
let out2 = ColorMatcher.corrections(measurements: [ref2, tgt2], referenceID: "builtin")
check(approx(out2["ext-A"]!.greenGain, tc.greenGain, 1e-6), "camera gain cancels (green)")
check(approx(out2["ext-A"]!.redGain, tc.redGain, 1e-6), "camera gain cancels (red)")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Sources/SyncBrightness/ColorMatcher.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: compile error — `ColorMatcher` / `DisplayMeasurement` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SyncBrightness/ColorMatcher.swift`:

```swift
import Foundation

struct DisplayMeasurement {
  let displayID: String
  let samples: PatchSamples
}

/// Turns photographed patch samples into a per-display ColorCorrection relative
/// to a reference display. Uses only WITHIN-photo channel ratios so the unknown
/// per-photo camera gain cancels. White-point (warm/cool) is the part the camera
/// neutralizes, so it is applied damped.
enum ColorMatcher {
  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String,
                          whitePointDamping: Double = 0.3) -> [String: ColorCorrection] {

    // Intrinsic channel "balance" of a display from mid-gray relative to white.
    // (camGain * emittedGray) / (camGain * emittedWhite) = emittedGray/emittedWhite — gain cancels.
    func balance(_ s: PatchSamples) -> (r: Double, g: Double, b: Double) {
      func ratio(_ num: Double, _ den: Double) -> Double { den > 1e-6 ? num / den : 1 }
      return (ratio(s.gray50.r, s.white.r),
              ratio(s.gray50.g, s.white.g),
              ratio(s.gray50.b, s.white.b))
    }

    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [:] }
    let refBal = balance(ref.samples)

    var result: [String: ColorCorrection] = [:]
    for m in measurements {
      if m.displayID == referenceID { result[m.displayID] = .identity; continue }
      let b = balance(m.samples)

      // Per-channel gain that makes this display's gray-balance match the reference.
      func gain(_ refCh: Double, _ ch: Double) -> Double { ch > 1e-6 ? refCh / ch : 1 }
      var r = gain(refBal.r, b.r)
      var g = gain(refBal.g, b.g)
      var bl = gain(refBal.b, b.b)

      // Damped white-point nudge: compare luminance-normalized white chroma.
      func norm(_ c: RGB) -> (r: Double, g: Double, b: Double) {
        let l = (c.r + c.g + c.b) / 3
        return l > 1e-6 ? (c.r / l, c.g / l, c.b / l) : (1, 1, 1)
      }
      let rw = norm(ref.samples.white), tw = norm(m.samples.white)
      func wp(_ refCh: Double, _ ch: Double) -> Double {
        let full = ch > 1e-6 ? refCh / ch : 1
        return 1 + (full - 1) * whitePointDamping
      }
      r *= wp(rw.r, tw.r); g *= wp(rw.g, tw.g); bl *= wp(rw.b, tw.b)

      // We can only attenuate (gamma max <= 1): normalize so the brightest channel is 1.
      let peak = max(r, max(g, bl))
      if peak > 1e-6 { r /= peak; g /= peak; bl /= peak }

      result[m.displayID] = ColorCorrection(redGain: r, greenGain: g, blueGain: bl, gamma: 1)
    }
    return result
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Sources/SyncBrightness/ColorMatcher.swift Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncBrightness/ColorMatcher.swift Tests/ColorChecks/main.swift
git commit -m "feat: ColorMatcher derives per-display corrections (camera gain cancels)"
```

- [ ] **Step 6: Register the color driver in `run-tests.sh`**

In `run-tests.sh`, after the `hotkey-checks` block, add:

```bash
run_check color-checks \
  Sources/SyncBrightness/ColorCorrection.swift \
  Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift \
  Tests/ColorChecks/main.swift
```

Run: `./run-tests.sh`
Expected: `curve-checks`, `hotkey-checks`, `color-checks` all pass.

```bash
git add run-tests.sh && git commit -m "test: run color-checks in run-tests.sh"
```

---

## Phase 3 — `PatchCardAnalyzer` (photo → PatchSamples)

The patch card is a known 4×2 grid: row 0 = white, gray50, gray25, (unused); row 1 = red, green, blue, (unused), with four **corner fiducial markers** in pure cyan/magenta/yellow/black at the card's corners for location + perspective rectification. The analyzer finds the four markers by color, computes a homography, and samples each cell's median.

### Task 4: `PatchCardAnalyzer.sample(image:)`

**Files:**
- Create: `Sources/SyncBrightness/PatchCardAnalyzer.swift`
- Test: `Tests/ColorChecks/main.swift` (extend) — synthetic flat (non-perspective) card image.

- [ ] **Step 1: Write the failing test** — append before the summary print. This renders a known card to a `CGImage` in memory (no perspective) and asserts the sampler recovers the planted patch colors.

```swift
import CoreGraphics

// Render a flat patch card: 4 fiducials at corners, patches in known cells.
func renderCard(width: Int = 400, height: Int = 200) -> CGImage {
  let cs = CGColorSpaceCreateDeviceRGB()
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ r: Double, _ g: Double, _ b: Double) {
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
  }
  fill(0, 0, width, height, 0, 0, 0) // black background
  // Fiducials (cyan TL, magenta TR, yellow BL, black-on-white BR marker = white square)
  let m = 20
  fill(0, height - m, m, m, 0, 1, 1)            // TL cyan (top-left in image coords)
  fill(width - m, height - m, m, m, 1, 0, 1)    // TR magenta
  fill(0, 0, m, m, 1, 1, 0)                     // BL yellow
  fill(width - m, 0, m, m, 1, 1, 1)             // BR white
  // Patch cells (inside the fiducial rectangle). Two rows, three columns.
  let gx = m + 10, gy = m + 10, gw = width - 2 * (m + 10), gh = height - 2 * (m + 10)
  let cw = gw / 3, chh = gh / 2
  // Row 1 (top of card): white, gray50, gray25
  fill(gx + 0 * cw, gy + chh, cw, chh, 1.0, 1.0, 1.0)
  fill(gx + 1 * cw, gy + chh, cw, chh, 0.5, 0.5, 0.5)
  fill(gx + 2 * cw, gy + chh, cw, chh, 0.25, 0.25, 0.25)
  // Row 0 (bottom of card): red, green, blue
  fill(gx + 0 * cw, gy, cw, chh, 1.0, 0.0, 0.0)
  fill(gx + 1 * cw, gy, cw, chh, 0.0, 1.0, 0.0)
  fill(gx + 2 * cw, gy, cw, chh, 0.0, 0.0, 1.0)
  return ctx.makeImage()!
}

let card = renderCard()
if let s = PatchCardAnalyzer.sample(image: card) {
  check(approx(s.white.r, 1.0, 0.05) && approx(s.white.g, 1.0, 0.05), "white patch sampled")
  check(approx(s.gray50.r, 0.5, 0.06), "gray50 patch sampled")
  check(approx(s.red.r, 1.0, 0.05) && s.red.g < 0.1, "red patch sampled")
  check(approx(s.blue.b, 1.0, 0.05) && s.blue.r < 0.1, "blue patch sampled")
} else {
  check(false, "PatchCardAnalyzer returned nil on a clean card")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift Sources/SyncBrightness/PatchCardAnalyzer.swift \
  Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks
```
Expected: compile error — `PatchCardAnalyzer` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SyncBrightness/PatchCardAnalyzer.swift`. v1 detection assumes a roughly axis-aligned shot (the on-screen card fills most of the frame): find each fiducial color's centroid, take the bounding quad, then sample cell centers via bilinear interpolation across the quad. (Full off-axis homography is a future enhancement; the bilinear quad map already tolerates moderate keystone.)

```swift
import CoreGraphics
import Foundation

enum PatchCardAnalyzer {
  /// Returns nil if the four fiducials can't be located.
  static func sample(image: CGImage) -> PatchSamples? {
    guard let px = Pixels(image) else { return nil }

    // Locate fiducial centroids by nearest-color voting.
    guard let tl = px.centroid(matching: (0, 1, 1)),   // cyan
          let tr = px.centroid(matching: (1, 0, 1)),   // magenta
          let bl = px.centroid(matching: (1, 1, 0)),   // yellow
          let br = px.centroidWhiteCorner() else { return nil }

    // Quad corners (in image space). Card grid is inset from the fiducials.
    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    // Bilinear map (u,v) in 0...1 over the quad TL->TR (u), TL->BL (v).
    func map(_ u: Double, _ v: Double) -> CGPoint {
      let top = lerp(tl, tr, u), bottom = lerp(bl, br, u)
      return lerp(top, bottom, v)
    }

    // Cell centers: inset 8% from fiducials, 3 cols x 2 rows.
    let inset = 0.10
    func cellCenter(col: Int, row: Int) -> CGPoint {
      let u = inset + (Double(col) + 0.5) / 3.0 * (1 - 2 * inset)
      let v = inset + (Double(row) + 0.5) / 2.0 * (1 - 2 * inset)
      return map(u, v)
    }
    func patch(col: Int, row: Int) -> RGB {
      px.median(around: cellCenter(col: col, row: row), radiusFraction: 0.04)
    }

    // Row 0 = top of card visually = white/gray50/gray25 (v small near TL).
    return PatchSamples(
      white:  patch(col: 0, row: 0),
      gray50: patch(col: 1, row: 0),
      gray25: patch(col: 2, row: 0),
      red:    patch(col: 0, row: 1),
      green:  patch(col: 1, row: 1),
      blue:   patch(col: 2, row: 1))
  }
}

/// Minimal RGB pixel accessor over a CGImage.
private struct Pixels {
  let w: Int, h: Int
  let data: [UInt8]   // RGBA8

  init?(_ image: CGImage) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    self.w = w; self.h = h; self.data = buf
  }

  func rgb(_ x: Int, _ y: Int) -> RGB {
    let i = (y * w + x) * 4
    return RGB(r: Double(data[i]) / 255, g: Double(data[i+1]) / 255, b: Double(data[i+2]) / 255)
  }

  /// Centroid of pixels closest to a saturated target color (cyan/magenta/yellow).
  func centroid(matching t: (Double, Double, Double)) -> CGPoint? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: 0, to: w, by: 2) {
        let c = rgb(x, y)
        let d = abs(c.r - t.0) + abs(c.g - t.1) + abs(c.b - t.2)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        if d < 0.4 && sat > 0.4 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 20 ? CGPoint(x: sx / n, y: sy / n) : nil
  }

  /// The white BR marker: brightest, lowest-saturation cluster in the right half.
  func centroidWhiteCorner() -> CGPoint? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: w / 2, to: w, by: 2) {
        let c = rgb(x, y)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        let lum = (c.r + c.g + c.b) / 3
        if lum > 0.85 && sat < 0.1 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 20 ? CGPoint(x: sx / n, y: sy / n) : nil
  }

  /// Per-channel median over a square window around p.
  func median(around p: CGPoint, radiusFraction: Double) -> RGB {
    let rad = max(2, Int(Double(min(w, h)) * radiusFraction))
    var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
    let cx = Int(p.x), cy = Int(p.y)
    for y in max(0, cy - rad)...min(h - 1, cy + rad) {
      for x in max(0, cx - rad)...min(w - 1, cx + rad) {
        let c = rgb(x, y); rs.append(c.r); gs.append(c.g); bs.append(c.b)
      }
    }
    func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    return RGB(r: med(rs), g: med(gs), b: med(bs))
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift Sources/SyncBrightness/PatchCardAnalyzer.swift \
  Tests/ColorChecks/main.swift -o /tmp/colorchecks && /tmp/colorchecks
```
Expected: `ALL PASS`.

- [ ] **Step 5: Add the analyzer to `run-tests.sh`'s `color-checks` block** (append the source path):

```bash
run_check color-checks \
  Sources/SyncBrightness/ColorCorrection.swift \
  Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift \
  Sources/SyncBrightness/PatchCardAnalyzer.swift \
  Tests/ColorChecks/main.swift
```

Run: `./run-tests.sh`
Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SyncBrightness/PatchCardAnalyzer.swift run-tests.sh Tests/ColorChecks/main.swift
git commit -m "feat: PatchCardAnalyzer locates + samples the patch card"
```

---

## Phase 4 — `CalibrationServer` + QR + phone page

### Task 5: The phone page HTML

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncPage.swift`

- [ ] **Step 1: Create the page** (no test — static asset). The page shows the current instruction, a native-camera file input, uploads the chosen photo, then polls `/next`.

Create `Sources/SyncBrightness/ColorSyncPage.swift`:

```swift
enum ColorSyncPage {
  /// `token` is interpolated so every request carries it.
  static func html(token: String) -> String {
    """
    <!doctype html><html><head><meta charset=utf-8>
    <meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1">
    <title>Color Sync</title>
    <style>
      body{font:-apple-system,system-ui;margin:0;background:#111;color:#eee;
        display:flex;flex-direction:column;align-items:center;justify-content:center;
        min-height:100vh;text-align:center;padding:24px;box-sizing:border-box}
      h1{font-size:22px;margin:0 0 8px} p{opacity:.8;margin:0 0 24px}
      label{display:inline-block;background:#0a84ff;color:#fff;padding:16px 28px;
        border-radius:14px;font-size:18px;font-weight:600}
      input{display:none} .done{color:#30d158}
    </style></head><body>
    <h1 id=step>Connecting…</h1>
    <p id=hint></p>
    <label id=btn style="display:none">Photograph this screen
      <input id=file type=file accept="image/*" capture="environment"></label>
    <script>
      const token = "\(token)";
      const stepEl = document.getElementById('step');
      const hintEl = document.getElementById('hint');
      const btn = document.getElementById('btn');
      const file = document.getElementById('file');
      async function poll(){
        const r = await fetch('/next?token='+token);
        const s = await r.json();
        stepEl.textContent = s.title;
        hintEl.textContent = s.hint || '';
        btn.style.display = s.capture ? 'inline-block' : 'none';
        if(s.done){ btn.style.display='none'; stepEl.className='done'; return; }
        if(!s.capture) setTimeout(poll, 800);
      }
      file.addEventListener('change', async () => {
        if(!file.files[0]) return;
        stepEl.textContent = 'Uploading…'; btn.style.display='none';
        await fetch('/upload?token='+token+'&display='+encodeURIComponent(btn.dataset.display||''),
          {method:'POST', headers:{'Content-Type':'image/jpeg'}, body:file.files[0]});
        file.value=''; poll();
      });
      poll();
    </script></body></html>
    """
  }
}
```

> Note for executor: `btn.dataset.display` is set from the poll payload in Task 7 wiring; the page reads `s.display` and stores it. Add to `poll()`: `if(s.display) btn.dataset.display = s.display;`

- [ ] **Step 2: Commit**

```bash
git add Sources/SyncBrightness/ColorSyncPage.swift
git commit -m "feat: color-sync phone page (native-camera file upload)"
```

---

### Task 6: `CalibrationServer` (NWListener HTTP)

A minimal HTTP/1.1 server: routes `GET /` (page), `GET /next` (JSON step), `POST /upload` (image bytes). Token required on every request. Drives a small state machine the Mac side advances.

**Files:**
- Create: `Sources/SyncBrightness/CalibrationServer.swift`

- [ ] **Step 1: Implement the server**

Create `Sources/SyncBrightness/CalibrationServer.swift`:

```swift
import Foundation
import Network

/// Token-gated, session-scoped HTTP server for the color-sync flow.
/// All callbacks are delivered on the main queue.
final class CalibrationServer {
  struct Step: Codable {
    var title: String
    var hint: String?
    var display: String?   // identifier of the display being photographed
    var capture: Bool      // show the capture button
    var done: Bool
  }

  private var listener: NWListener?
  private let token = UUID().uuidString
  private var port: UInt16 = 0

  /// Current step served to the phone (set by the Mac-side controller).
  var step = Step(title: "Get ready…", hint: nil, display: nil, capture: false, done: false)
  /// Called with the uploaded JPEG bytes + the display id the phone reported.
  var onUpload: ((Data, String) -> Void)?

  /// Starts listening; returns the URL to encode in the QR (http://<ip>:<port>/?token=…).
  @discardableResult
  func start() throws -> URL {
    let params = NWParameters.tcp
    let listener = try NWListener(using: params)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
    listener.stateUpdateHandler = { _ in }
    listener.start(queue: .global(qos: .userInitiated))
    // Wait briefly for the OS-assigned port.
    var assigned: UInt16 = 0
    for _ in 0..<50 { if let p = listener.port?.rawValue { assigned = p; break }; usleep(10_000) }
    self.port = assigned
    let ip = Self.lanIPv4() ?? "127.0.0.1"
    return URL(string: "http://\(ip):\(assigned)/?token=\(token)")!
  }

  func stop() { listener?.cancel(); listener = nil }

  private func handle(_ conn: NWConnection) {
    conn.start(queue: .global(qos: .userInitiated))
    receive(conn, buffer: Data())
  }

  private func receive(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isDone, err in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }
      if let req = HTTPRequest(buf), req.isComplete {
        self.route(req, conn)
      } else if isDone || err != nil {
        conn.cancel()
      } else {
        self.receive(conn, buffer: buf)
      }
    }
  }

  private func route(_ req: HTTPRequest, _ conn: NWConnection) {
    guard req.query["token"] == token else { return respond(conn, 403, "text/plain", Data("forbidden".utf8)) }
    switch (req.method, req.path) {
    case ("GET", "/"):
      respond(conn, 200, "text/html; charset=utf-8", Data(ColorSyncPage.html(token: token).utf8))
    case ("GET", "/next"):
      let json = (try? JSONEncoder().encode(step)) ?? Data("{}".utf8)
      respond(conn, 200, "application/json", json)
    case ("POST", "/upload"):
      let display = req.query["display"] ?? ""
      let body = req.body
      DispatchQueue.main.async { self.onUpload?(body, display) }
      respond(conn, 200, "application/json", Data("{\"ok\":true}".utf8))
    default:
      respond(conn, 404, "text/plain", Data("not found".utf8))
    }
  }

  private func respond(_ conn: NWConnection, _ code: Int, _ type: String, _ body: Data) {
    var head = "HTTP/1.1 \(code) OK\r\n"
    head += "Content-Type: \(type)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8); out.append(body)
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
  }

  /// First non-loopback IPv4 address (en0/en…).
  static func lanIPv4() -> String? {
    var addr: String?
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
      let flags = Int32(cur.pointee.ifa_flags)
      let fam = cur.pointee.ifa_addr.pointee.sa_family
      if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
         fam == UInt8(AF_INET),
         let name = cur.pointee.ifa_name, String(cString: name).hasPrefix("en") {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(cur.pointee.ifa_addr, socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)
        if !ip.hasPrefix("127.") { addr = ip; break }
      }
      p = cur.pointee.ifa_next
    }
    freeifaddrs(ifap)
    return addr
  }
}

/// Tiny HTTP request parser (request line + headers + optional body by Content-Length).
private struct HTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data
  let isComplete: Bool

  init?(_ data: Data) {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
      self.init(empty: data); return
    }
    let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    let reqLine = lines.first?.components(separatedBy: " ") ?? []
    guard reqLine.count >= 2 else { return nil }
    method = reqLine[0]
    let target = reqLine[1]
    var q: [String: String] = [:]
    let parts = target.components(separatedBy: "?")
    path = parts[0]
    if parts.count > 1 {
      for kv in parts[1].components(separatedBy: "&") {
        let p = kv.components(separatedBy: "=")
        if p.count == 2 { q[p[0]] = p[1].removingPercentEncoding ?? p[1] }
      }
    }
    query = q
    var h: [String: String] = [:]
    for line in lines.dropFirst() {
      let p = line.components(separatedBy: ": ")
      if p.count == 2 { h[p[0].lowercased()] = p[1] }
    }
    headers = h
    let bodyStart = headerEnd.upperBound
    let available = data.subdata(in: bodyStart..<data.endIndex)
    let expected = Int(h["content-length"] ?? "0") ?? 0
    body = available
    isComplete = available.count >= expected
  }

  private init(empty data: Data) {
    method = ""; path = ""; query = [:]; headers = [:]; body = Data(); isComplete = false
  }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Manual smoke test** (server reachable, page served)

Add a temporary scratch in a Swift REPL is awkward; instead verify via the integrated flow in Phase 5. For now confirm compilation only.

- [ ] **Step 4: Commit**

```bash
git add Sources/SyncBrightness/CalibrationServer.swift
git commit -m "feat: CalibrationServer (NWListener HTTP, token-gated)"
```

---

## Phase 5 — Patch-card window, UI flow, persistence, wiring

### Task 7: `PatchCardWindow` — render the card fullscreen on a display

**Files:**
- Create: `Sources/SyncBrightness/PatchCardWindow.swift`

- [ ] **Step 1: Implement** — a borderless window placed on a target `NSScreen`, drawing the same layout `PatchCardAnalyzer` expects (fiducials at corners; white/gray50/gray25 top row; red/green/blue bottom row).

Create `Sources/SyncBrightness/PatchCardWindow.swift`:

```swift
import Cocoa

final class PatchCardWindow {
  private var window: NSWindow?

  func show(on screen: NSScreen) {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.isOpaque = true
    w.backgroundColor = .black
    w.setFrame(screen.frame, display: true)
    w.contentView = PatchCardView(frame: screen.frame)
    w.makeKeyAndOrderFront(nil)
    window = w
  }

  func hide() { window?.orderOut(nil); window = nil }
}

private final class PatchCardView: NSView {
  override var isFlipped: Bool { false }
  override func draw(_ dirty: NSRect) {
    NSColor.black.setFill(); bounds.fill()
    let m: CGFloat = 64
    func box(_ r: NSRect, _ c: NSColor) { c.setFill(); r.fill() }
    // Fiducials (match analyzer: cyan TL, magenta TR, yellow BL, white BR — image coords flipped).
    box(NSRect(x: 0, y: bounds.maxY - m, width: m, height: m), .cyan)             // top-left
    box(NSRect(x: bounds.maxX - m, y: bounds.maxY - m, width: m, height: m), .magenta) // top-right
    box(NSRect(x: 0, y: 0, width: m, height: m), .yellow)                          // bottom-left
    box(NSRect(x: bounds.maxX - m, y: 0, width: m, height: m), .white)             // bottom-right
    // Grid inset.
    let gx = m + 30, gy = m + 30
    let gw = bounds.width - 2 * gx, gh = bounds.height - 2 * gy
    let cw = gw / 3, chh = gh / 2
    func cell(_ col: Int, _ row: Int) -> NSRect {
      NSRect(x: CGFloat(gx) + CGFloat(col) * cw, y: CGFloat(gy) + CGFloat(row) * chh, width: cw, height: chh)
    }
    // Bottom row (row 0): red green blue. Top row (row 1): white gray50 gray25.
    box(cell(0, 0), .init(red: 1, green: 0, blue: 0, alpha: 1))
    box(cell(1, 0), .init(red: 0, green: 1, blue: 0, alpha: 1))
    box(cell(2, 0), .init(red: 0, green: 0, blue: 1, alpha: 1))
    box(cell(0, 1), .init(white: 1.0, alpha: 1))
    box(cell(1, 1), .init(white: 0.5, alpha: 1))
    box(cell(2, 1), .init(white: 0.25, alpha: 1))
  }
}
```

- [ ] **Step 2: Build check**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/SyncBrightness/PatchCardWindow.swift
git commit -m "feat: PatchCardWindow renders the calibration card fullscreen"
```

---

### Task 8: Persist `[String: ColorCorrection]` and apply via `SyncController`

Mirror the existing brightness-profile persistence (`AppDelegate.swift:493-502`, keyed by `ExternalDisplay.id`). Add a `SyncController` entry point to apply a correction map on its serial queue.

**Files:**
- Modify: `Sources/SyncBrightness/SyncController.swift`
- Modify: `Sources/SyncBrightness/AppDelegate.swift`

- [ ] **Step 1: Add the apply API to `SyncController`** — add this method to `SyncController` (uses the existing `gamma` which is now a `DisplayColorState`, and the existing `externals` array of `ExternalDisplay` with `.id` and `.cgDisplayID`):

```swift
  /// Apply per-display color corrections keyed by ExternalDisplay.id. Runs on the
  /// serial queue; safe to call after reconnect/wake. Missing ids clear to identity.
  func applyColorCorrections(_ map: [String: ColorCorrection]) {
    queue.async {
      for display in self.externals {
        let c = map[display.id] ?? .identity
        self.gamma.setCorrection(display.cgDisplayID, c)
      }
    }
  }
```

- [ ] **Step 2: Add persistence to `AppDelegate`** — alongside the brightness `profilesKey` machinery, add:

```swift
  private let colorProfilesKey = "colorCorrectionProfiles"

  private func loadColorCorrections() -> [String: ColorCorrection] {
    guard let data = UserDefaults.standard.data(forKey: colorProfilesKey),
          let decoded = try? JSONDecoder().decode([String: ColorCorrection].self, from: data)
    else { return [:] }
    return decoded
  }

  private func saveColorCorrections(_ map: [String: ColorCorrection]) {
    if let data = try? JSONEncoder().encode(map) {
      UserDefaults.standard.set(data, forKey: colorProfilesKey)
    }
    controller.applyColorCorrections(map)   // re-apply live (controller var name per AppDelegate)
  }
```

> Executor: match the actual `SyncController` property name in `AppDelegate` (grep for the existing controller instance; it is the one that already receives `onMonitors`/`onUpdate`). Re-apply `loadColorCorrections()` wherever brightness profiles are re-applied on wake/reconnect (search for where `profiles` is pushed to the controller and add the color equivalent).

- [ ] **Step 3: Build check**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/SyncBrightness/SyncController.swift Sources/SyncBrightness/AppDelegate.swift
git commit -m "feat: persist + apply per-display color corrections"
```

---

### Task 9: `ColorSyncWindowController` — QR, flow orchestration, fine-tune, Save

Ties everything together: starts `CalibrationServer`, shows the QR, advances the step per display, shows the patch card on each display, feeds uploads to `PatchCardAnalyzer` → `ColorMatcher`, applies live, offers per-display warm↔cool/brightness sliders, and Saves.

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncWindowController.swift`
- Modify: `Sources/SyncBrightness/ControlWindowController.swift` (add a "Color Sync (beta)" button + `onColorSync` callback)
- Modify: `Sources/SyncBrightness/AppDelegate.swift` (instantiate + present the window; wire `onColorSync`)

- [ ] **Step 1: Implement the controller**

Create `Sources/SyncBrightness/ColorSyncWindowController.swift`:

```swift
import Cocoa
import CoreImage

final class ColorSyncWindowController: NSWindowController {
  /// (displayID string, NSScreen, friendly label) for each display to calibrate.
  var displays: [(id: String, screen: NSScreen, label: String)] = []
  /// Called when the user saves corrections.
  var onSave: (([String: ColorCorrection]) -> Void)?

  private let server = CalibrationServer()
  private let card = PatchCardWindow()
  private var index = 0
  private var samples: [String: PatchSamples] = [:]
  private let imageView = NSImageView()
  private let statusLabel = NSTextField(labelWithString: "")

  convenience init() {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Color Sync (beta)"
    self.init(window: w)
    let stack = NSStackView(views: [statusLabel, imageView])
    stack.orientation = .vertical; stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    w.contentView?.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
      stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24),
    ])
  }

  func begin() {
    do {
      let url = try server.start()
      statusLabel.stringValue = "Scan with your phone (same Wi-Fi):\n\(url.absoluteString)"
      imageView.image = Self.qr(for: url.absoluteString)
    } catch {
      statusLabel.stringValue = "Could not start server: \(error.localizedDescription)"
      return
    }
    server.onUpload = { [weak self] data, _ in self?.handleUpload(data) }
    index = 0
    presentStep()
    showWindow(nil)
  }

  private func presentStep() {
    guard index < displays.count else { finishCapture(); return }
    let d = displays[index]
    card.show(on: d.screen)
    server.step = .init(title: "Photograph “\(d.label)”",
                        hint: "Fill the frame with the screen. Avoid glare.",
                        display: d.id, capture: true, done: false)
  }

  private func handleUpload(_ data: Data) {
    card.hide()
    guard index < displays.count,
          let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let s = PatchCardAnalyzer.sample(image: img) else {
      // Couldn't read — re-show the same step with a retake hint.
      let d = displays[index]
      card.show(on: d.screen)
      server.step = .init(title: "Couldn’t read it — try again",
                          hint: "Less angle, avoid reflections.",
                          display: displays[index].id, capture: true, done: false)
      return
    }
    samples[displays[index].id] = s
    index += 1
    server.step = .init(title: "Got it — next…", hint: nil, display: nil, capture: false, done: false)
    presentStep()
  }

  private func finishCapture() {
    let referenceID = displays.first?.id ?? ""   // first in list = reference (built-in when present)
    let measurements = samples.map { DisplayMeasurement(displayID: $0.key, samples: $0.value) }
    let corrections = ColorMatcher.corrections(measurements: measurements, referenceID: referenceID)
    onSave?(corrections)
    server.step = .init(title: "Done! Colors matched.", hint: "You can put your phone down.",
                        display: nil, capture: false, done: true)
    statusLabel.stringValue = "Calibration applied and saved."
    // Fine-tune sliders are added here in a follow-up step (Task 10).
  }

  override func close() { server.stop(); card.hide(); super.close() }

  static func qr(for string: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size); img.addRepresentation(rep)
    return img
  }
}
```

- [ ] **Step 2: Add the entry point in `ControlWindowController`** — add a button labeled "Color Sync (beta)…" in the General (or Displays) tab whose action calls a new `var onColorSync: () -> Void` (follow the existing callback pattern used by `onReset` at `ControlWindowController.swift:511`).

- [ ] **Step 3: Wire it in `AppDelegate`** — build the `displays` list (built-in first as reference, then externals), present the controller, and persist on save:

```swift
  private var colorSync: ColorSyncWindowController?

  private func openColorSync() {
    let c = ColorSyncWindowController()
    // Built-in first (reference), then externals. Map ExternalDisplay.id <-> NSScreen via cgDisplayID.
    c.displays = buildColorSyncDisplayList()   // helper using NSScreen.screens + controller.externals
    c.onSave = { [weak self] map in self?.saveColorCorrections(map) }
    c.begin()
    colorSync = c
  }
```

> Executor: `buildColorSyncDisplayList()` pairs each `NSScreen` with the matching `ExternalDisplay.id` via `CGDirectDisplayID` (screen's `NSDeviceDescription["NSScreenNumber"]`), labeling the built-in "Built-in" and using `ExternalDisplay.name` otherwise. The built-in screen is `NSScreen` whose `CGDisplayIsBuiltin(id)` is true; put it first so it becomes the reference.

- [ ] **Step 4: Build + full test**

Run: `swift build && ./run-tests.sh`
Expected: builds; all checks pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Color Sync window — QR, capture flow, apply + save"
```

---

### Task 10: Fine-tune sliders + before/after toggle

**Files:**
- Modify: `Sources/SyncBrightness/ColorSyncWindowController.swift`

- [ ] **Step 1: Add per-display warm↔cool + brightness sliders** after `finishCapture()`. A warm↔cool slider biases red vs blue gain around the computed correction; brightness scales all three gains; a "Before/After" checkbox toggles between `.identity` and the computed map by calling `onSave` with each. Each slider change calls `onSave?(adjustedMap)` so it applies live. "Save" persists the current adjusted map (already wired via `onSave` → `saveColorCorrections`).

```swift
  // Maps a warm/cool bias (-1...1) and brightness (0.5...1) onto a base correction.
  static func adjust(_ base: ColorCorrection, warmCool: Double, brightness: Double) -> ColorCorrection {
    let warm = 1 + 0.15 * warmCool      // >1 boosts red, <1 boosts blue
    var r = base.redGain * warm * brightness
    var g = base.greenGain * brightness
    var b = base.blueGain / warm * brightness
    let peak = max(r, max(g, b))
    if peak > 1 { r /= peak; g /= peak; b /= peak }
    return ColorCorrection(redGain: r, greenGain: g, blueGain: b, gamma: base.gamma)
  }
```

- [ ] **Step 2: Add a unit check** for `adjust` in `Tests/ColorChecks/main.swift`:

```swift
do {
  let base = ColorCorrection(redGain: 1, greenGain: 1, blueGain: 1, gamma: 1)
  let warm = ColorSyncAdjust.adjust(base, warmCool: 1, brightness: 1)
  check(warm.redGain > warm.blueGain, "warm bias boosts red over blue")
  let dim = ColorSyncAdjust.adjust(base, warmCool: 0, brightness: 0.5)
  check(approx(dim.redGain, 0.5) && approx(dim.blueGain, 0.5), "brightness scales gains")
}
```

> Executor: to keep `adjust` testable without Cocoa, move it into a tiny `enum ColorSyncAdjust` in `ColorMatcher.swift` (pure), and have `ColorSyncWindowController` call `ColorSyncAdjust.adjust`. Add `Sources/SyncBrightness/ColorMatcher.swift` is already in the `color-checks` compile list, so no `run-tests.sh` change is needed.

- [ ] **Step 3: Run tests**

Run: `./run-tests.sh`
Expected: all pass including the new `adjust` checks.

- [ ] **Step 4: Build the app and smoke-test the whole flow on hardware**

Run: `./build.sh && open "build/Monitor Brightness Sync.app"`
Manual: open Settings → Color Sync (beta) → scan QR on phone (same Wi-Fi) → photograph each screen → confirm corrections apply and persist across relaunch.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: color-sync fine-tune sliders + before/after toggle"
```

---

### Task 11: README + caveats

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the feature** under Features and Caveats: phone-camera color sync (relative matching), the same-LAN / no-client-isolation requirement, white-point best-effort caveat, and that color correction shares the per-display gamma write with sub-floor dimming and the non-DDC follow.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document phone-camera color sync"
```

---

## Self-review notes (for the executor)

- **Spec coverage:** goal/scope (Task 3 ColorMatcher honesty + Task 10 manual fine-tune), architecture/components (all phases), algorithm (Tasks 3–4), user flow (Tasks 5–9), persistence/lifecycle/security (Tasks 6, 8, 9 — token in `CalibrationServer`, session-scoped start/stop, in-memory photos), test plan (Tasks 1–4, 10). README caveats (Task 11).
- **Known approximations to revisit during execution:** (1) `PatchCardAnalyzer` uses a bilinear quad map, not a full homography — fine for near-axis on-screen shots; off-axis robustness is a future enhancement. (2) `CalibrationServer.start()` busy-waits briefly for the assigned port; acceptable for a one-shot session. (3) The white-point damping constant (0.3) and warm/cool range (±0.15) are starting values to tune on real hardware.
- **Threading:** every gamma/correction mutation goes through `SyncController.queue` (Task 8). UI/server callbacks marshal to main (`CalibrationServer.onUpload` dispatches to main).
- **No-regression:** `DisplayColorState.formula(dim:correction:.identity)` is asserted byte-identical to the old `GammaDimmer` output (Task 2).
```
