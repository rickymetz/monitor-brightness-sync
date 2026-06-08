# Native Color Sync — Plan A (macOS side + shared core)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the entire macOS side of native color sync — the locked-camera correction math, the patch card, the session coordinator, the LAN transport, and the UI/persistence — fully exercisable with unit tests and a *simulated in-process phone*, no iOS device required.

**Architecture:** A pure correction core (`ColorMatcher`, `PatchCardLayout`, `PatchCardAnalyzer`) plus a transport-agnostic `ColorSyncSession` state machine driven by an abstract peer. A `Network.framework` TLS-PSK transport implements the peer for real; a fake peer drives it in tests. The Mac shows a `PatchCardWindow` per display, runs the session, computes per-display `ColorCorrection`s, and applies them through the existing `DisplayColorState` (Task 2) on `SyncController`'s serial queue.

**Tech Stack:** Swift + SwiftPM, Cocoa, CoreGraphics (gamma + pixels), Network.framework (NWListener TLS-PSK), CoreImage (CIQRCodeGenerator). No third-party deps. Framework-free tests via `run-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-06-08-native-color-sync-design.md`

**Reuses (already on branch `color-sync-feature`):** `ColorCorrection`/`RGB`/`PatchSamples` (Task 1), `DisplayColorState` (Task 2). The web-era `ColorMatcher` was reverted; this plan writes the locked-camera version.

**Note on `ColorSyncCore`:** the spec's shared package is created in **Plan B** (when the iOS app needs it). In Plan A the shared-pure files (`ColorMatcher.swift`, `PatchCardLayout.swift`, `PatchCardAnalyzer.swift`) live in `Sources/SyncBrightness/` and import only `Foundation`/`CoreGraphics` (never Cocoa), so Plan B can move them into the package by relocation + adding `import ColorSyncCore`.

---

## File structure (Plan A)

| File | Responsibility |
|---|---|
| `Sources/SyncBrightness/ColorCorrection.swift` | (exists) value types. This plan adds `Codable` to `PatchSamples` (needed for transport). |
| `Sources/SyncBrightness/ColorMatcher.swift` | (new) locked-camera matcher: `[DisplayMeasurement]` + referenceID → `[String: ColorCorrection]`. Pure. |
| `Sources/SyncBrightness/PatchCardLayout.swift` | (new) canonical patch/fiducial geometry in normalized coords. Pure. Shared by renderer + analyzer. |
| `Sources/SyncBrightness/PatchCardAnalyzer.swift` | (new) photo (CGImage) → `PatchSamples`. Pure (Foundation/CoreGraphics only). |
| `Sources/SyncBrightness/ColorSyncMessages.swift` | (new) `MacToPhone` / `PhoneToMac` Codable+Equatable enums; `DisplayRef`; `ColorSyncPeer` protocol. |
| `Sources/SyncBrightness/ColorSyncSession.swift` | (new) transport-agnostic session state machine. Pure (driven by a `ColorSyncPeer`). |
| `Sources/SyncBrightness/ColorSyncTransport.swift` | (new) NWListener TLS-PSK + length-prefixed JSON framing; conforms to `ColorSyncPeer`. macOS. |
| `Sources/SyncBrightness/ColorSyncQR.swift` | (new) `CIQRCodeGenerator` → `NSImage`. |
| `Sources/SyncBrightness/PatchCardWindow.swift` | (new) fullscreen patch card on a chosen `NSScreen` using `PatchCardLayout`. |
| `Sources/SyncBrightness/ColorSyncAdjust.swift` | (new) pure fine-tune helper (warm/cool + brightness → adjusted `ColorCorrection`). |
| `Sources/SyncBrightness/ColorSyncWindowController.swift` | (new) Mac UI: QR, status, before/after, sliders, Save. |
| `Sources/SyncBrightness/SyncController.swift` | (modify) add `applyColorCorrections(_:)`. |
| `Sources/SyncBrightness/AppDelegate.swift` | (modify) persistence + open the window + build the display list. |
| `Sources/SyncBrightness/ControlWindowController.swift` | (modify) "Color Sync (beta)" button + `onColorSync` callback. |
| `Tests/ColorChecks/main.swift` | (extend) matcher, layout, analyzer, session, adjust checks. |
| `run-tests.sh` | (modify) `color-checks` driver compiling the new pure files. |

---

## Task A1: locked-camera `ColorMatcher` (+ `PatchSamples` Codable)

**Files:**
- Modify: `Sources/SyncBrightness/ColorCorrection.swift`
- Create: `Sources/SyncBrightness/ColorMatcher.swift`
- Modify: `run-tests.sh`
- Test: `Tests/ColorChecks/main.swift`

- [ ] **Step 1: Make `PatchSamples` Codable.** In `ColorCorrection.swift`, change the `PatchSamples` declaration line from `struct PatchSamples: Equatable {` to `struct PatchSamples: Equatable, Codable {` and update its comment to: `/// Median patch colors sampled from one photo. Codable for transport over the wire.`

- [ ] **Step 2: Write the failing test.** Append to `Tests/ColorChecks/main.swift` before the final summary block:

```swift
// ---- ColorMatcher (locked camera) ----
func samplesWithWhite(_ w: RGB) -> PatchSamples {
  PatchSamples(white: w,
               gray50: RGB(r: w.r/2, g: w.g/2, b: w.b/2),
               gray25: RGB(r: w.r/4, g: w.g/4, b: w.b/4),
               red: RGB(r: w.r, g: 0, b: 0),
               green: RGB(r: 0, g: w.g, b: 0),
               blue: RGB(r: 0, g: 0, b: w.b))
}
// One fixed camera gain G applied to ALL photos in a session (the locked-camera model).
func applyG(_ s: PatchSamples, _ gr: Double, _ gg: Double, _ gb: Double) -> PatchSamples {
  func m(_ c: RGB) -> RGB { RGB(r: c.r*gr, g: c.g*gg, b: c.b*gb) }
  return PatchSamples(white: m(s.white), gray50: m(s.gray50), gray25: m(s.gray25),
                      red: m(s.red), green: m(s.green), blue: m(s.blue))
}

do {
  // Reference renders neutral white; target renders a warm (red-heavy) white.
  let refS = applyG(samplesWithWhite(RGB(r: 1.0, g: 1.0, b: 1.0)), 0.8, 0.8, 0.8)
  let tgtS = applyG(samplesWithWhite(RGB(r: 1.2, g: 1.0, b: 1.0)), 0.8, 0.8, 0.8)
  let out = ColorMatcher.corrections(
    measurements: [DisplayMeasurement(displayID: "builtin", samples: refS),
                   DisplayMeasurement(displayID: "ext", samples: tgtS)],
    referenceID: "builtin")
  check(out["builtin"] == .identity, "reference -> identity")
  let c = out["ext"]!
  check(c.redGain < c.greenGain && c.redGain < c.blueGain, "warm target: red attenuated most")
  check(approx(max(c.redGain, max(c.greenGain, c.blueGain)), 1.0), "gains normalized: peak == 1")
  // exact: gains pre-normalize = (1/1.2, 1, 1); peak 1 -> unchanged
  check(approx(c.redGain, 1.0/1.2) && approx(c.greenGain, 1.0) && approx(c.blueGain, 1.0), "exact gains")

  // Camera-gain independence: a DIFFERENT but still-constant G yields identical corrections.
  let refS2 = applyG(samplesWithWhite(RGB(r: 1.0, g: 1.0, b: 1.0)), 1.7, 0.5, 1.1)
  let tgtS2 = applyG(samplesWithWhite(RGB(r: 1.2, g: 1.0, b: 1.0)), 1.7, 0.5, 1.1)
  let out2 = ColorMatcher.corrections(
    measurements: [DisplayMeasurement(displayID: "builtin", samples: refS2),
                   DisplayMeasurement(displayID: "ext", samples: tgtS2)],
    referenceID: "builtin")
  check(approx(out2["ext"]!.redGain, c.redGain), "locked G cancels (red)")
  check(approx(out2["ext"]!.blueGain, c.blueGain), "locked G cancels (blue)")
}
```

- [ ] **Step 3: Run to confirm failure.**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/ColorMatcher.swift Tests/ColorChecks/main.swift -o /tmp/cc && /tmp/cc`
Expected: compile error — `ColorMatcher`/`DisplayMeasurement` undefined.

- [ ] **Step 4: Implement.** Create `Sources/SyncBrightness/ColorMatcher.swift`:

```swift
import Foundation

struct DisplayMeasurement {
  let displayID: String
  let samples: PatchSamples
}

/// Locked-camera color matcher. All photos in a session share ONE fixed camera
/// transform G (the iOS app locks WB + exposure once), so the per-channel ratio
/// of two displays' measured whites equals the ratio of their emitted whites — G
/// cancels. We correct chroma only (attenuate-only, peak channel normalized to 1)
/// so overall brightness is left to the brightness-sync feature.
enum ColorMatcher {
  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String) -> [String: ColorCorrection] {
    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [:] }
    let rw = ref.samples.white

    var result: [String: ColorCorrection] = [:]
    for m in measurements {
      if m.displayID == referenceID { result[m.displayID] = .identity; continue }
      let tw = m.samples.white
      func gain(_ refC: Double, _ tgtC: Double) -> Double { tgtC > 1e-6 ? refC / tgtC : 1 }
      var r = gain(rw.r, tw.r)
      var g = gain(rw.g, tw.g)
      var b = gain(rw.b, tw.b)
      let peak = max(r, max(g, b))
      if peak > 1e-6 { r /= peak; g /= peak; b /= peak }
      result[m.displayID] = ColorCorrection(redGain: r, greenGain: g, blueGain: b, gamma: 1)
    }
    return result
  }
}
```

- [ ] **Step 5: Run to confirm pass.**

Run: `swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/ColorMatcher.swift Tests/ColorChecks/main.swift -o /tmp/cc && /tmp/cc`
Expected: all checks pass.

- [ ] **Step 6: Register `color-checks` in `run-tests.sh`.** After the `hotkey-checks` block add:

```bash
run_check color-checks \
  Sources/SyncBrightness/ColorCorrection.swift \
  Sources/SyncBrightness/DisplayColorState.swift \
  Sources/SyncBrightness/ColorMatcher.swift \
  Tests/ColorChecks/main.swift
```

Run: `./run-tests.sh`  → Expected: curve-checks, hotkey-checks, color-checks all pass.

- [ ] **Step 7: Commit.**

```bash
git add -A
git commit -m "feat: locked-camera ColorMatcher; PatchSamples Codable; wire color-checks"
```

---

## Task A2: `PatchCardLayout` (canonical geometry)

Shared geometry so the macOS renderer and the analyzer agree. Normalized coordinates: the card spans 0...1 in both axes; (0,0) = bottom-left. Fiducials sit in the corners; patches in a 3-column × 2-row grid inset from the fiducials.

**Files:**
- Create: `Sources/SyncBrightness/PatchCardLayout.swift`
- Test: `Tests/ColorChecks/main.swift`

- [ ] **Step 1: Write the failing test.** Append before the summary:

```swift
// ---- PatchCardLayout ----
do {
  // 3 columns x 2 rows; cell centers are evenly spaced inside the inset grid.
  let c00 = PatchCardLayout.cellCenter(col: 0, row: 0)
  let c20 = PatchCardLayout.cellCenter(col: 2, row: 0)
  check(c00.x < c20.x, "col 0 is left of col 2")
  let c01 = PatchCardLayout.cellCenter(col: 0, row: 1)
  check(c01.y > c00.y, "row 1 is above row 0")
  // patch roles: row 1 = white/gray50/gray25, row 0 = red/green/blue
  check(PatchCardLayout.role(col: 0, row: 1) == .white, "top-left is white")
  check(PatchCardLayout.role(col: 0, row: 0) == .red, "bottom-left is red")
  check(PatchCardLayout.allRoles.count == 6, "six patches")
}
```

- [ ] **Step 2: Run to confirm failure.**
Run: `swiftc Sources/SyncBrightness/PatchCardLayout.swift Tests/ColorChecks/main.swift Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Sources/SyncBrightness/ColorMatcher.swift -o /tmp/cc && /tmp/cc`
Expected: `PatchCardLayout` undefined.

- [ ] **Step 3: Implement.** Create `Sources/SyncBrightness/PatchCardLayout.swift`:

```swift
import CoreGraphics

/// Canonical patch-card geometry in normalized coordinates (0...1, origin bottom-left).
/// Shared by the macOS renderer (PatchCardWindow) and the analyzer so they agree.
enum PatchCardLayout {
  static let columns = 3
  static let rows = 2
  /// Grid inset from the card edges (fiducials live in the outer margin).
  static let inset = 0.12

  enum PatchRole { case white, gray50, gray25, red, green, blue }

  /// Row 1 (top): white, gray50, gray25. Row 0 (bottom): red, green, blue.
  static func role(col: Int, row: Int) -> PatchRole {
    switch (col, row) {
    case (0, 1): return .white
    case (1, 1): return .gray50
    case (2, 1): return .gray25
    case (0, 0): return .red
    case (1, 0): return .green
    default:     return .blue
    }
  }

  static var allRoles: [PatchRole] {
    [.white, .gray50, .gray25, .red, .green, .blue]
  }

  /// Normalized center of a grid cell.
  static func cellCenter(col: Int, row: Int) -> CGPoint {
    let u = inset + (Double(col) + 0.5) / Double(columns) * (1 - 2 * inset)
    let v = inset + (Double(row) + 0.5) / Double(rows) * (1 - 2 * inset)
    return CGPoint(x: u, y: v)
  }

  /// Normalized rect of a grid cell (for the renderer).
  static func cellRect(col: Int, row: Int) -> CGRect {
    let w = (1 - 2 * inset) / Double(columns)
    let h = (1 - 2 * inset) / Double(rows)
    let x = inset + Double(col) * w
    let y = inset + Double(row) * h
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// The sRGB color the renderer should fill for a role.
  static func fillColor(_ role: PatchRole) -> (r: Double, g: Double, b: Double) {
    switch role {
    case .white:  return (1, 1, 1)
    case .gray50: return (0.5, 0.5, 0.5)
    case .gray25: return (0.25, 0.25, 0.25)
    case .red:    return (1, 0, 0)
    case .green:  return (0, 1, 0)
    case .blue:   return (0, 0, 1)
    }
  }
}
```

- [ ] **Step 4: Run to confirm pass.** (same swiftc command as Step 2) → all pass.

- [ ] **Step 5: Add `PatchCardLayout.swift` to the `color-checks` block in `run-tests.sh`** (append its path to that `run_check`). Run `./run-tests.sh` → all pass.

- [ ] **Step 6: Commit.**
```bash
git add -A && git commit -m "feat: PatchCardLayout canonical geometry"
```

---

## Task A3: `PatchCardAnalyzer` (photo → PatchSamples)

Pure (Foundation/CoreGraphics only). Locates the four corner fiducials by color, maps the quad bilinearly, samples each cell's median via `PatchCardLayout`.

**Files:**
- Create: `Sources/SyncBrightness/PatchCardAnalyzer.swift`
- Test: `Tests/ColorChecks/main.swift`

- [ ] **Step 1: Write the failing test.** Append before the summary. It renders a flat (non-perspective) card to a CGImage and asserts recovery:

```swift
// ---- PatchCardAnalyzer ----
import CoreGraphics
func renderCard(width: Int = 600, height: Int = 400) -> CGImage {
  let cs = CGColorSpaceCreateDeviceRGB()
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ g: Double, _ b: Double) {
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
  }
  let W = Double(width), H = Double(height)
  fill(0, 0, W, H, 0, 0, 0)                          // black background
  let m = 30.0
  fill(0, H - m, m, m, 0, 1, 1)                      // TL cyan
  fill(W - m, H - m, m, m, 1, 0, 1)                  // TR magenta
  fill(0, 0, m, m, 1, 1, 0)                          // BL yellow
  fill(W - m, 0, m, m, 1, 1, 1)                      // BR white
  for col in 0..<3 {
    for row in 0..<2 {
      let r = PatchCardLayout.cellRect(col: col, row: row)
      let c = PatchCardLayout.fillColor(PatchCardLayout.role(col: col, row: row))
      fill(r.minX * W, r.minY * H, r.width * W, r.height * H, c.r, c.g, c.b)
    }
  }
  return ctx.makeImage()!
}
do {
  if let s = PatchCardAnalyzer.sample(image: renderCard()) {
    check(approx(s.white.r, 1.0, 0.06) && approx(s.white.g, 1.0, 0.06), "white sampled")
    check(approx(s.gray50.r, 0.5, 0.07), "gray50 sampled")
    check(s.red.r > 0.8 && s.red.g < 0.15, "red sampled")
    check(s.blue.b > 0.8 && s.blue.r < 0.15, "blue sampled")
  } else { check(false, "analyzer returned nil on a clean card") }
}
```

- [ ] **Step 2: Run to confirm failure** (add `Sources/SyncBrightness/PatchCardAnalyzer.swift` to the swiftc list):
`swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Sources/SyncBrightness/ColorMatcher.swift Sources/SyncBrightness/PatchCardLayout.swift Sources/SyncBrightness/PatchCardAnalyzer.swift Tests/ColorChecks/main.swift -o /tmp/cc && /tmp/cc`
Expected: `PatchCardAnalyzer` undefined.

- [ ] **Step 3: Implement.** Create `Sources/SyncBrightness/PatchCardAnalyzer.swift`:

```swift
import CoreGraphics
import Foundation

/// Locates the patch card in a photo via four corner fiducials, maps the quad,
/// and samples each patch cell's median color. Pure (no Cocoa). Returns nil if
/// the four fiducials can't be found.
enum PatchCardAnalyzer {
  static func sample(image: CGImage) -> PatchSamples? {
    guard let px = Pixels(image),
          let tl = px.centroid(matching: (0, 1, 1)),   // cyan  (top-left)
          let tr = px.centroid(matching: (1, 0, 1)),   // magenta (top-right)
          let bl = px.centroid(matching: (1, 1, 0)),   // yellow (bottom-left)
          let br = px.whiteCorner() else { return nil } // white (bottom-right)

    // Bilinear map of normalized (u,v) onto the detected quad. Image y is top-down;
    // PatchCardLayout v is bottom-up, so flip v.
    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    func map(_ u: Double, _ v: Double) -> CGPoint {
      let vv = 1 - v
      let top = lerp(tl, tr, u), bottom = lerp(bl, br, u)
      return lerp(top, bottom, vv)
    }
    func patch(col: Int, row: Int) -> RGB {
      let c = PatchCardLayout.cellCenter(col: col, row: row)
      return px.median(around: map(c.x, c.y), radiusFraction: 0.03)
    }
    return PatchSamples(
      white:  patch(col: 0, row: 1),
      gray50: patch(col: 1, row: 1),
      gray25: patch(col: 2, row: 1),
      red:    patch(col: 0, row: 0),
      green:  patch(col: 1, row: 0),
      blue:   patch(col: 2, row: 0))
  }
}

private struct Pixels {
  let w: Int, h: Int, data: [UInt8]
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
  func centroid(matching t: (Double, Double, Double)) -> CGPoint? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: 0, to: w, by: 2) {
        let c = rgb(x, y)
        let d = abs(c.r - t.0) + abs(c.g - t.1) + abs(c.b - t.2)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        if d < 0.5 && sat > 0.35 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 15 ? CGPoint(x: sx / n, y: sy / n) : nil
  }
  func whiteCorner() -> CGPoint? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: w / 2, to: w, by: 2) {  // bottom-right region
        if y > h / 2 { continue }
        let c = rgb(x, y)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        let lum = (c.r + c.g + c.b) / 3
        if lum > 0.85 && sat < 0.1 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 15 ? CGPoint(x: sx / n, y: sy / n) : nil
  }
  func median(around p: CGPoint, radiusFraction: Double) -> RGB {
    let rad = max(2, Int(Double(min(w, h)) * radiusFraction))
    let cx = Int(p.x), cy = Int(p.y)
    var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
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

Note: the analyzer renders `image` y-top-down (CGImage native), while the test renders with CoreGraphics y-bottom-up. `Pixels` draws the image into a top-down context, so detected fiducial points are in top-down pixel space; the `map` flips v to match. If the white-corner/fiducial detection mislocates on the synthetic image, adjust the `whiteCorner()` region predicate — the test is the oracle.

- [ ] **Step 4: Run to confirm pass** (same swiftc as Step 2). If a sampling assertion is off by more than its tolerance, the bug is in fiducial location or the v-flip — fix until green. Expected: all pass.

- [ ] **Step 5: Add `PatchCardAnalyzer.swift` to the `color-checks` block in `run-tests.sh`.** Run `./run-tests.sh` → all pass.

- [ ] **Step 6: Commit.**
```bash
git add -A && git commit -m "feat: PatchCardAnalyzer locates + samples the patch card"
```

---

## Task A4: messages + `ColorSyncSession` state machine

The transport-agnostic heart. Driven by an abstract `ColorSyncPeer`; tested with a fake peer (no network, no phone).

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncMessages.swift`
- Create: `Sources/SyncBrightness/ColorSyncSession.swift`
- Test: `Tests/ColorChecks/main.swift`

- [ ] **Step 1: Write the failing test.** Append before the summary:

```swift
// ---- ColorSyncSession ----
final class FakePeer: ColorSyncPeer {
  var sent: [MacToPhone] = []
  func send(_ m: MacToPhone) { sent.append(m) }
}
do {
  let peer = FakePeer()
  let displays = [DisplayRef(id: "builtin", label: "Built-in"),
                  DisplayRef(id: "ext", label: "Ext")]
  let session = ColorSyncSession(displays: displays, referenceID: "builtin", peer: peer)
  var shownCards: [String] = []
  var preparedRef: String? = nil
  var completed: [String: ColorCorrection]? = nil
  session.onShowCard = { shownCards.append($0) }
  session.onPrepareReference = { preparedRef = $0 }
  session.onComplete = { completed = $0 }

  session.start()
  check(session.state == .awaitingLock, "start -> awaitingLock")
  check(preparedRef == "builtin", "prepared reference display")
  check(peer.sent.last == .prepareLock(referenceLabel: "Built-in"), "sent prepareLock")

  session.handle(.locked)
  check(shownCards.last == "builtin", "show card on first display")
  check(peer.sent.last == .capture(displayID: "builtin", label: "Built-in"), "capture builtin")

  session.handle(.samples(displayID: "builtin", samples: samplesWithWhite(RGB(r: 1, g: 1, b: 1))))
  check(peer.sent.last == .capture(displayID: "ext", label: "Ext"), "advance to ext")

  session.handle(.samples(displayID: "ext", samples: samplesWithWhite(RGB(r: 1.2, g: 1, b: 1))))
  check(completed != nil, "completed corrections")
  check(completed!["builtin"] == .identity, "reference identity")
  check(completed!["ext"]!.redGain < 1.0, "ext warm -> red attenuated")
  check(peer.sent.last == .done, "sent done")
  check(session.state == .done, "state done")

  // Error path: a fresh session, error during capture -> retake same display.
  let peer2 = FakePeer()
  let s2 = ColorSyncSession(displays: displays, referenceID: "builtin", peer: peer2)
  s2.start(); s2.handle(.locked)
  s2.handle(.error(reason: "no card"))
  if case .retake(let id, _) = peer2.sent.last! { check(id == "builtin", "retake same display") }
  else { check(false, "expected retake after error") }
}
```

- [ ] **Step 2: Run to confirm failure** (add both new files to the swiftc list):
`swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/DisplayColorState.swift Sources/SyncBrightness/ColorMatcher.swift Sources/SyncBrightness/PatchCardLayout.swift Sources/SyncBrightness/PatchCardAnalyzer.swift Sources/SyncBrightness/ColorSyncMessages.swift Sources/SyncBrightness/ColorSyncSession.swift Tests/ColorChecks/main.swift -o /tmp/cc && /tmp/cc`
Expected: undefined symbols.

- [ ] **Step 3: Implement messages.** Create `Sources/SyncBrightness/ColorSyncMessages.swift`:

```swift
import Foundation

/// A display to calibrate (reference first). `id` is ExternalDisplay.id or "builtin".
struct DisplayRef: Equatable, Codable {
  let id: String
  let label: String
}

/// Coordinator (Mac) -> capture client (phone).
enum MacToPhone: Equatable, Codable {
  case prepareLock(referenceLabel: String)
  case capture(displayID: String, label: String)
  case retake(displayID: String, hint: String)
  case done
}

/// Capture client (phone) -> coordinator (Mac).
enum PhoneToMac: Equatable, Codable {
  case paired
  case locked
  case samples(displayID: String, samples: PatchSamples)
  case error(reason: String)
}

/// Abstraction over the wire so the session is testable with a fake peer.
protocol ColorSyncPeer: AnyObject {
  func send(_ message: MacToPhone)
}
```

- [ ] **Step 4: Implement the session.** Create `Sources/SyncBrightness/ColorSyncSession.swift`:

```swift
import Foundation

/// Transport-agnostic color-sync coordinator. Sequences: lock -> capture each
/// display -> compute corrections. Pure logic; UI/display side effects via callbacks.
final class ColorSyncSession {
  enum State: Equatable { case idle, awaitingLock, capturing(index: Int), done }

  let displays: [DisplayRef]
  let referenceID: String
  private weak var peer: ColorSyncPeer?

  private(set) var state: State = .idle
  private(set) var collected: [String: PatchSamples] = [:]

  /// Show the patch card fullscreen on this display id.
  var onShowCard: ((String) -> Void)?
  /// Show the neutral mid-gray lock target on the reference display id.
  var onPrepareReference: ((String) -> Void)?
  /// Final corrections, ready to apply + persist.
  var onComplete: (([String: ColorCorrection]) -> Void)?

  init(displays: [DisplayRef], referenceID: String, peer: ColorSyncPeer) {
    self.displays = displays
    self.referenceID = referenceID
    self.peer = peer
  }

  func start() {
    guard state == .idle, !displays.isEmpty else { return }
    state = .awaitingLock
    onPrepareReference?(referenceID)
    let refLabel = displays.first(where: { $0.id == referenceID })?.label ?? "the reference"
    peer?.send(.prepareLock(referenceLabel: refLabel))
  }

  func handle(_ message: PhoneToMac) {
    switch (state, message) {
    case (.awaitingLock, .locked):
      beginCapture(index: 0)

    case (.capturing(let i), .samples(let id, let s)) where id == displays[i].id:
      collected[id] = s
      if i + 1 < displays.count { beginCapture(index: i + 1) } else { finish() }

    case (.capturing(let i), .error):
      peer?.send(.retake(displayID: displays[i].id, hint: "Less angle, avoid glare; fill the frame."))

    default:
      break // ignore out-of-order messages
    }
  }

  private func beginCapture(index i: Int) {
    state = .capturing(index: i)
    onShowCard?(displays[i].id)
    peer?.send(.capture(displayID: displays[i].id, label: displays[i].label))
  }

  private func finish() {
    let measurements = collected.map { DisplayMeasurement(displayID: $0.key, samples: $0.value) }
    let corrections = ColorMatcher.corrections(measurements: measurements, referenceID: referenceID)
    state = .done
    peer?.send(.done)
    onComplete?(corrections)
  }
}
```

- [ ] **Step 5: Run to confirm pass** (same swiftc as Step 2). Expected: all pass.

- [ ] **Step 6: Add both files to the `color-checks` block in `run-tests.sh`** (append `ColorSyncMessages.swift` and `ColorSyncSession.swift`). Run `./run-tests.sh` → all pass.

- [ ] **Step 7: Commit.**
```bash
git add -A && git commit -m "feat: ColorSyncSession state machine + wire messages"
```

---

## Task A5: `ColorSyncTransport` (NWListener TLS-PSK + framing)

Concrete network implementation of `ColorSyncPeer`. Build-verified; the session logic it carries is already unit-tested via the fake peer.

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncTransport.swift`

- [ ] **Step 1: Implement.** Create `Sources/SyncBrightness/ColorSyncTransport.swift`:

```swift
import Foundation
import Network
import CryptoKit

/// LAN transport for color sync: a TLS-PSK NWListener that frames length-prefixed
/// JSON. Conforms to ColorSyncPeer (sends MacToPhone), and surfaces decoded
/// PhoneToMac messages on the main queue.
final class ColorSyncTransport: ColorSyncPeer {
  struct ConnectionInfo { let host: String; let port: UInt16; let psk: String }

  private var listener: NWListener?
  private var connection: NWConnection?
  private let psk: String
  private var port: UInt16 = 0

  var onReceive: ((PhoneToMac) -> Void)?
  var onClientConnected: (() -> Void)?

  init() {
    self.psk = ColorSyncTransport.randomPSK()
  }

  /// Start listening; returns the info to encode in the QR.
  func start() throws -> ConnectionInfo {
    let opts = NWProtocolTLS.Options()
    let key = SymmetricKey(data: Data(psk.utf8))
    key.withUnsafeBytes { raw in
      let d = DispatchData(bytes: raw)
      sec_protocol_options_add_pre_shared_key(
        opts.securityProtocolOptions,
        d as __DispatchData,
        (("colorsync".data(using: .utf8)!) as NSData) as DispatchData as __DispatchData)
    }
    let params = NWParameters(tls: opts)
    let listener = try NWListener(using: params)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    listener.start(queue: .main)
    for _ in 0..<100 { if let p = listener.port?.rawValue { port = p; break }; usleep(10_000) }
    let host = CalibrationHost.lanIPv4() ?? "127.0.0.1"
    return ConnectionInfo(host: host, port: port, psk: psk)
  }

  func stop() {
    connection?.cancel(); connection = nil
    listener?.cancel(); listener = nil
  }

  private func accept(_ conn: NWConnection) {
    connection = conn
    conn.start(queue: .main)
    receiveFrame(conn)
    DispatchQueue.main.async { [weak self] in self?.onClientConnected?() }
  }

  // MARK: ColorSyncPeer
  func send(_ message: MacToPhone) {
    guard let conn = connection, let body = try? JSONEncoder().encode(message) else { return }
    var frame = Data()
    var len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
    frame.append(body)
    conn.send(content: frame, completion: .contentProcessed { _ in })
  }

  // Length-prefixed (UInt32 BE) JSON frames.
  private func receiveFrame(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, err in
      guard let self, let header, header.count == 4, err == nil else { conn.cancel(); return }
      let len = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
      guard len > 0, len < 4_000_000 else { conn.cancel(); return }
      conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, err2 in
        guard let body, err2 == nil else { conn.cancel(); return }
        if let msg = try? JSONDecoder().decode(PhoneToMac.self, from: body) {
          DispatchQueue.main.async { self.onReceive?(msg) }
        }
        self.receiveFrame(conn)
      }
    }
  }

  private static func randomPSK() -> String {
    let key = SymmetricKey(size: .bits128)
    return key.withUnsafeBytes { Data($0).base64EncodedString() }
  }
}

/// LAN IPv4 helper (first non-loopback en* interface).
enum CalibrationHost {
  static func lanIPv4() -> String? {
    var address: String?
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
        if !ip.hasPrefix("127.") { address = ip; break }
      }
      p = cur.pointee.ifa_next
    }
    freeifaddrs(ifap)
    return address
  }
}
```

- [ ] **Step 2: Build-verify.** Run: `swift build`
Expected: builds. If the `sec_protocol_options_add_pre_shared_key` signature differs on the SDK in use, adjust the call to the current Network.framework PSK API (the intent: register `psk` as the pre-shared key with identity "colorsync"). The PSK identity/key wiring is the only SDK-sensitive part; everything else is standard.

- [ ] **Step 3: Commit.**
```bash
git add -A && git commit -m "feat: ColorSyncTransport (NWListener TLS-PSK, JSON framing)"
```

---

## Task A6: `ColorSyncQR`

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncQR.swift`

- [ ] **Step 1: Implement.** Create `Sources/SyncBrightness/ColorSyncQR.swift`:

```swift
import Cocoa
import CoreImage

enum ColorSyncQR {
  /// Encode connection info as a compact URL the iOS app parses:
  /// mbsync://pair?h=<host>&p=<port>&k=<psk-base64url>
  static func payload(host: String, port: UInt16, psk: String) -> String {
    let k = psk.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? psk
    return "mbsync://pair?h=\(host)&p=\(port)&k=\(k)"
  }

  static func image(for string: String, scale: CGFloat = 10) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size); img.addRepresentation(rep)
    return img
  }
}
```

- [ ] **Step 2: Build-verify.** `swift build` → builds.

- [ ] **Step 3: Commit.**
```bash
git add -A && git commit -m "feat: ColorSyncQR (pairing payload + QR image)"
```

---

## Task A7: `PatchCardWindow`

**Files:**
- Create: `Sources/SyncBrightness/PatchCardWindow.swift`

- [ ] **Step 1: Implement.** Create `Sources/SyncBrightness/PatchCardWindow.swift` (renders the same `PatchCardLayout` the analyzer expects; also a neutral mid-gray mode for the lock step):

```swift
import Cocoa

final class PatchCardWindow {
  private var window: NSWindow?

  enum Content { case midGray, patchCard }

  func show(_ content: Content, on screen: NSScreen) {
    let w = window ?? makeWindow(on: screen)
    w.setFrame(screen.frame, display: true)
    (w.contentView as? PatchCardView)?.content = content
    w.contentView?.needsDisplay = true
    w.makeKeyAndOrderFront(nil)
    window = w
  }

  func hide() { window?.orderOut(nil); window = nil }

  private func makeWindow(on screen: NSScreen) -> NSWindow {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.isOpaque = true
    w.backgroundColor = .black
    w.contentView = PatchCardView(frame: screen.frame)
    return w
  }
}

private final class PatchCardView: NSView {
  var content: PatchCardWindow.Content = .patchCard

  override func draw(_ dirty: NSRect) {
    if content == .midGray {
      NSColor(white: 0.5, alpha: 1).setFill(); bounds.fill(); return
    }
    NSColor.black.setFill(); bounds.fill()
    let m: CGFloat = 64
    func box(_ r: NSRect, _ c: NSColor) { c.setFill(); r.fill() }
    box(NSRect(x: 0, y: bounds.maxY - m, width: m, height: m), .cyan)              // TL
    box(NSRect(x: bounds.maxX - m, y: bounds.maxY - m, width: m, height: m), .magenta) // TR
    box(NSRect(x: 0, y: 0, width: m, height: m), .yellow)                          // BL
    box(NSRect(x: bounds.maxX - m, y: 0, width: m, height: m), .white)             // BR
    for col in 0..<PatchCardLayout.columns {
      for row in 0..<PatchCardLayout.rows {
        let nr = PatchCardLayout.cellRect(col: col, row: row)
        let rect = NSRect(x: nr.minX * bounds.width, y: nr.minY * bounds.height,
                          width: nr.width * bounds.width, height: nr.height * bounds.height)
        let c = PatchCardLayout.fillColor(PatchCardLayout.role(col: col, row: row))
        box(rect, NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
      }
    }
  }
}
```

- [ ] **Step 2: Build-verify.** `swift build` → builds.

- [ ] **Step 3: Commit.**
```bash
git add -A && git commit -m "feat: PatchCardWindow (patch card + mid-gray lock target)"
```

---

## Task A8: persist + apply corrections

Mirror the brightness-profile persistence (`AppDelegate.swift` ~line 493, keyed by `ExternalDisplay.id`). Add an apply entry point on `SyncController`.

**Files:**
- Modify: `Sources/SyncBrightness/SyncController.swift`
- Modify: `Sources/SyncBrightness/AppDelegate.swift`

- [ ] **Step 1: Add the apply API to `SyncController`.** Add this method to the `SyncController` class body (it uses the existing `gamma` — now a `DisplayColorState` — and the existing `externals: [ExternalDisplay]` with `.id`/`.cgDisplayID`, all on the serial `queue`):

```swift
  /// Apply per-display color corrections keyed by ExternalDisplay.id. Runs on the
  /// serial queue; missing ids reset to identity. Safe after reconnect/wake.
  func applyColorCorrections(_ map: [String: ColorCorrection]) {
    queue.async {
      for display in self.externals {
        guard let cg = display.cgDisplayID else { continue }
        self.gamma.setCorrection(cg, map[display.id] ?? .identity)
      }
    }
  }
```

- [ ] **Step 2: Build-verify.** `swift build` → builds.

- [ ] **Step 3: Add persistence to `AppDelegate`.** First read `AppDelegate.swift` to find the `SyncController` instance name (the object that already receives `onMonitors`/`onUpdate`; search for where brightness `profiles` are saved around line 493) and where profiles are re-applied on wake/reconnect. Then add, alongside the brightness profile machinery:

```swift
  private let colorProfilesKey = "colorCorrectionProfiles"

  func loadColorCorrections() -> [String: ColorCorrection] {
    guard let data = UserDefaults.standard.data(forKey: colorProfilesKey),
          let decoded = try? JSONDecoder().decode([String: ColorCorrection].self, from: data)
    else { return [:] }
    return decoded
  }

  func saveColorCorrections(_ map: [String: ColorCorrection]) {
    if let data = try? JSONEncoder().encode(map) {
      UserDefaults.standard.set(data, forKey: colorProfilesKey)
    }
    controller.applyColorCorrections(map)   // use the actual controller property name
  }
```

Then, wherever the app re-applies brightness profiles after a display set change / wake (search for the call that pushes `profiles` into the controller), add a sibling call `controller.applyColorCorrections(loadColorCorrections())`. Replace `controller` with the real property name found in Step 3.

- [ ] **Step 4: Build-verify.** `swift build && ./run-tests.sh` → builds; all checks pass.

- [ ] **Step 5: Commit.**
```bash
git add -A && git commit -m "feat: persist + apply per-display color corrections"
```

---

## Task A9: `ColorSyncWindowController` + entry point

Ties transport + session + windows + UI together.

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncWindowController.swift`
- Modify: `Sources/SyncBrightness/ControlWindowController.swift`
- Modify: `Sources/SyncBrightness/AppDelegate.swift`

- [ ] **Step 1: Implement the controller.** Create `Sources/SyncBrightness/ColorSyncWindowController.swift`:

```swift
import Cocoa

final class ColorSyncWindowController: NSWindowController {
  /// (display id, NSScreen, label). Reference first (built-in when present).
  var displays: [(id: String, screen: NSScreen, label: String)] = []
  var onSave: (([String: ColorCorrection]) -> Void)?

  private let transport = ColorSyncTransport()
  private let card = PatchCardWindow()
  private var session: ColorSyncSession?
  private var corrections: [String: ColorCorrection] = [:]

  private let imageView = NSImageView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  convenience init() {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Color Sync (beta)"
    self.init(window: w)
    let stack = NSStackView(views: [statusLabel, imageView])
    stack.orientation = .vertical; stack.spacing = 16; stack.alignment = .centerX
    stack.translatesAutoresizingMaskIntoConstraints = false
    w.contentView?.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
      stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
    ])
  }

  func begin() {
    let refs = displays.map { DisplayRef(id: $0.id, label: $0.label) }
    guard let referenceID = displays.first?.id else {
      statusLabel.stringValue = "No displays found."
      showWindow(nil); return
    }
    do {
      let info = try transport.start()
      let payload = ColorSyncQR.payload(host: info.host, port: info.port, psk: info.psk)
      imageView.image = ColorSyncQR.image(for: payload)
      statusLabel.stringValue = "Open Monitor Brightness Sync on your iPhone (same Wi-Fi) and scan this code."
    } catch {
      statusLabel.stringValue = "Could not start: \(error.localizedDescription)"
      showWindow(nil); return
    }

    let session = ColorSyncSession(displays: refs, referenceID: referenceID, peer: transport)
    session.onPrepareReference = { [weak self] id in
      guard let screen = self?.screen(for: id) else { return }
      self?.card.show(.midGray, on: screen)
      self?.statusLabel.stringValue = "Aim your phone at the reference screen and hold steady to lock."
    }
    session.onShowCard = { [weak self] id in
      guard let screen = self?.screen(for: id), let label = self?.label(for: id) else { return }
      self?.card.show(.patchCard, on: screen)
      self?.statusLabel.stringValue = "Photographing \(label)…"
    }
    session.onComplete = { [weak self] map in
      self?.corrections = map
      self?.card.hide()
      self?.onSave?(map)                  // apply live immediately
      self?.presentFineTune()
    }
    self.session = session
    transport.onReceive = { [weak self] msg in self?.session?.handle(msg) }
    transport.onClientConnected = { [weak self] in self?.session?.start() }
    showWindow(nil)
  }

  private func presentFineTune() {
    statusLabel.stringValue = "Done — colors matched. Fine-tune below, then Save."
    imageView.image = nil
    // Fine-tune sliders are added in Task A10.
  }

  private func screen(for id: String) -> NSScreen? { displays.first(where: { $0.id == id })?.screen }
  private func label(for id: String) -> String? { displays.first(where: { $0.id == id })?.label }

  override func close() {
    transport.stop(); card.hide(); super.close()
  }
}
```

- [ ] **Step 2: Add the entry point to `ControlWindowController`.** Read `ControlWindowController.swift` and follow the existing callback pattern (e.g. `onReset` near line 511). Add a stored `var onColorSync: () -> Void = {}` and a button titled "Color Sync (beta)…" in the General tab whose target action calls `onColorSync()`. Match the surrounding button-construction style in that file.

- [ ] **Step 3: Wire it in `AppDelegate`.** Add:

```swift
  private var colorSyncWC: ColorSyncWindowController?

  func openColorSync() {
    let wc = ColorSyncWindowController()
    wc.displays = buildColorSyncDisplayList()
    wc.onSave = { [weak self] map in self?.saveColorCorrections(map) }
    wc.begin()
    colorSyncWC = wc
  }

  /// Built-in first (reference), then externals, pairing each NSScreen to a display id.
  private func buildColorSyncDisplayList() -> [(id: String, screen: NSScreen, label: String)] {
    var out: [(id: String, screen: NSScreen, label: String)] = []
    for screen in NSScreen.screens {
      guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let cg = CGDirectDisplayID(num.uint32Value)
      if CGDisplayIsBuiltin(cg) != 0 {
        out.insert((id: "builtin", screen: screen, label: "Built-in"), at: 0)
      } else if let ext = controller.externals.first(where: { $0.cgDisplayID == cg }) {
        out.append((id: ext.id, screen: screen, label: ext.name))
      }
    }
    return out
  }
```

Set `controlWindowController.onColorSync = { [weak self] in self?.openColorSync() }` where the control window is created (match the existing `onReset`/callback wiring). Replace `controller` with the real `SyncController` property name. `controller.externals` must be readable from the main thread for this snapshot — if `externals` is queue-private, add a `SyncController` accessor `func snapshotExternals() -> [(id: String, cg: CGDirectDisplayID?, name: String)] { queue.sync { externals.map { ($0.id, $0.cgDisplayID, $0.name) } } }` and use it here instead of touching `externals` directly.

- [ ] **Step 4: Build-verify.** `swift build && ./run-tests.sh` → builds; checks pass.

- [ ] **Step 5: Commit.**
```bash
git add -A && git commit -m "feat: Color Sync window — QR pairing, session orchestration, apply"
```

---

## Task A10: fine-tune sliders + before/after

**Files:**
- Create: `Sources/SyncBrightness/ColorSyncAdjust.swift`
- Modify: `Sources/SyncBrightness/ColorSyncWindowController.swift`
- Test: `Tests/ColorChecks/main.swift`
- Modify: `run-tests.sh`

- [ ] **Step 1: Write the failing test.** Append before the summary:

```swift
// ---- ColorSyncAdjust ----
do {
  let base = ColorCorrection(redGain: 1, greenGain: 1, blueGain: 1, gamma: 1)
  let warm = ColorSyncAdjust.adjust(base, warmCool: 1, brightness: 1)
  check(warm.redGain > warm.blueGain, "warm bias boosts red over blue")
  let cool = ColorSyncAdjust.adjust(base, warmCool: -1, brightness: 1)
  check(cool.blueGain > cool.redGain, "cool bias boosts blue over red")
  let dim = ColorSyncAdjust.adjust(base, warmCool: 0, brightness: 0.5)
  check(approx(dim.redGain, 0.5) && approx(dim.blueGain, 0.5), "brightness scales gains")
}
```

- [ ] **Step 2: Run to confirm failure** (add `ColorSyncAdjust.swift` to the swiftc list):
`swiftc Sources/SyncBrightness/ColorCorrection.swift Sources/SyncBrightness/ColorSyncAdjust.swift Tests/ColorChecks/main.swift -o /tmp/cc && /tmp/cc`
Expected: `ColorSyncAdjust` undefined.

- [ ] **Step 3: Implement.** Create `Sources/SyncBrightness/ColorSyncAdjust.swift`:

```swift
import Foundation

/// Pure fine-tune: bias an automatic correction by a warm/cool dial (-1...1) and a
/// brightness scale (0.5...1), keeping gains in 0...1.
enum ColorSyncAdjust {
  static func adjust(_ base: ColorCorrection, warmCool: Double, brightness: Double) -> ColorCorrection {
    let warm = 1 + 0.15 * warmCool     // >1 favors red, <1 favors blue
    var r = base.redGain * warm * brightness
    let g = base.greenGain * brightness
    var b = base.blueGain / warm * brightness
    let peak = max(r, max(g, b))
    if peak > 1 { r /= peak; b /= peak }   // only clamp if we exceeded 1
    return ColorCorrection(redGain: min(1, r), greenGain: min(1, g), blueGain: min(1, b), gamma: base.gamma)
  }
}
```

Note: with `brightness: 0.5` and identity base, `r=g=b=0.5`, peak 0.5 (<1) so no renorm — matches the `dim` test.

- [ ] **Step 4: Run to confirm pass** (same swiftc as Step 2) → all pass.

- [ ] **Step 5: Add sliders to `ColorSyncWindowController.presentFineTune()`.** For each non-reference display, add a labeled row with a warm↔cool `NSSlider` (-1...1, default 0) and a brightness `NSSlider` (0.5...1, default 1), plus a "Before/After" `NSButton` checkbox. On any change, recompute `adjusted = corrections.mapValues { ColorSyncAdjust.adjust($0, warmCool: wc, brightness: br) }` for that display (identity for reference) and call `onSave?(adjusted)` to apply live. The Before/After checkbox toggles `onSave?(checked ? [:] /*identity everywhere*/ : adjustedMap)`. A "Save" button calls `onSave?(adjustedMap)` (persist) and closes. Keep the per-display slider values in a small dictionary on the controller. Build the rows with the same AppKit idiom used elsewhere in the file.

- [ ] **Step 6: Add `ColorSyncAdjust.swift` to the `color-checks` block in `run-tests.sh`.** Run `swift build && ./run-tests.sh` → builds; all pass.

- [ ] **Step 7: Commit.**
```bash
git add -A && git commit -m "feat: color-sync fine-tune sliders + before/after"
```

---

## Task A11: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the feature** under Features and Caveats: native phone-camera color sync (relative white-point matching via a locked-camera iOS companion), the same-Wi-Fi/no-isolation requirement, that the iOS app is separate (TestFlight), and that color correction shares the per-display gamma write with sub-floor dimming and the non-DDC follow. Note the iOS app lives in `ios/` (Plan B).

- [ ] **Step 2: Commit.**
```bash
git add README.md && git commit -m "docs: document native color sync (macOS side)"
```

---

## Self-review notes (for the executor)

- **Spec coverage:** §3a core (A1–A4), §4 transport (A5–A6), §5 capture protocol (A4 session + A9 wiring), §6 matcher (A1), §7 card/analyzer (A2–A3, A7), §8 persistence/lifecycle/security (A8, A9 transport TLS-PSK, A5), §9 testing (A1–A4 + A10 unit; A9 manual), README (A11). The iOS app (§3c) is **Plan B**.
- **Threading:** `applyColorCorrections` runs on `SyncController.queue` (A8); transport callbacks marshal to main (A5).
- **Reuse:** `DisplayColorState.setCorrection` (Task 2) is the apply primitive; `ColorCorrection`/`PatchSamples` (Task 1) flow through unchanged (PatchSamples gains `Codable` in A1).
- **Integration unknowns flagged for the executor:** the `SyncController` property name in `AppDelegate`, the `externals` thread-safety accessor, and the `ControlWindowController` button idiom — each task says to read the file and match the existing pattern. The Network.framework PSK call (A5) is the one SDK-version-sensitive spot.
- **Deferred to Plan B:** extracting the pure files into the `ColorSyncCore` package; the iOS capture app; TestFlight signing.
```
