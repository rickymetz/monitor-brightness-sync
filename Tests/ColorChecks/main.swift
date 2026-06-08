import Foundation
import CoreGraphics

var failures = 0

func check(_ condition: Bool, _ message: String) {
  if condition {
    print("  ✓ \(message)")
  } else {
    print("  ✗ \(message)")
    failures += 1
  }
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

print("Color checks")

// ColorCorrection.identity is a no-op
let id = ColorCorrection.identity
check(id.redGain == 1 && id.greenGain == 1 && id.blueGain == 1 && id.gamma == 1, "identity is unit")

// Codable round-trips
let c = ColorCorrection(redGain: 0.9, greenGain: 1.0, blueGain: 0.8, gamma: 1.0)
let data = try! JSONEncoder().encode(c)
let back = try! JSONDecoder().decode(ColorCorrection.self, from: data)
check(back == c, "ColorCorrection codable round-trip")

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
  check(approx(Double(f.red.max), 0.4), "red max == dim*redGain")
  check(approx(Double(f.blue.max), 0.3), "blue max == dim*blueGain")
  check(approx(Double(f.green.max), 0.5), "green max == dim*greenGain")
}

// ---- ColorMatcher (locked camera) ----
func samplesWithWhite(_ w: RGB) -> PatchSamples {
  PatchSamples(white: w,
               gray50: RGB(r: w.r/2, g: w.g/2, b: w.b/2),
               gray25: RGB(r: w.r/4, g: w.g/4, b: w.b/4),
               red: RGB(r: w.r, g: 0, b: 0),
               green: RGB(r: 0, g: w.g, b: 0),
               blue: RGB(r: 0, g: 0, b: w.b))
}
func applyG(_ s: PatchSamples, _ gr: Double, _ gg: Double, _ gb: Double) -> PatchSamples {
  func m(_ c: RGB) -> RGB { RGB(r: c.r*gr, g: c.g*gg, b: c.b*gb) }
  return PatchSamples(white: m(s.white), gray50: m(s.gray50), gray25: m(s.gray25),
                      red: m(s.red), green: m(s.green), blue: m(s.blue))
}
do {
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
  check(approx(c.redGain, 1.0/1.2) && approx(c.greenGain, 1.0) && approx(c.blueGain, 1.0), "exact gains")
  let refS2 = applyG(samplesWithWhite(RGB(r: 1.0, g: 1.0, b: 1.0)), 1.7, 0.5, 1.1)
  let tgtS2 = applyG(samplesWithWhite(RGB(r: 1.2, g: 1.0, b: 1.0)), 1.7, 0.5, 1.1)
  let out2 = ColorMatcher.corrections(
    measurements: [DisplayMeasurement(displayID: "builtin", samples: refS2),
                   DisplayMeasurement(displayID: "ext", samples: tgtS2)],
    referenceID: "builtin")
  check(approx(out2["ext"]!.redGain, c.redGain), "locked G cancels (red)")
  check(approx(out2["ext"]!.greenGain, c.greenGain), "locked G cancels (green)")
  check(approx(out2["ext"]!.blueGain, c.blueGain), "locked G cancels (blue)")
}

// ---- PatchCardLayout ----
do {
  let c00 = PatchCardLayout.cellCenter(col: 0, row: 0)
  let c20 = PatchCardLayout.cellCenter(col: 2, row: 0)
  check(c00.x < c20.x, "col 0 is left of col 2")
  let c01 = PatchCardLayout.cellCenter(col: 0, row: 1)
  check(c01.y > c00.y, "row 1 is above row 0")
  check(PatchCardLayout.role(col: 0, row: 1) == .white, "top-left is white")
  check(PatchCardLayout.role(col: 0, row: 0) == .red, "bottom-left is red")
  check(PatchCardLayout.allRoles.count == 6, "six patches")
}

// ---- PatchCardAnalyzer ----
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
  fill(0, 0, W, H, 0, 0, 0)
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

  let peer2 = FakePeer()
  let s2 = ColorSyncSession(displays: displays, referenceID: "builtin", peer: peer2)
  s2.start(); s2.handle(.locked)
  s2.handle(.error(reason: "no card"))
  if case .retake(let id, _) = peer2.sent.last! { check(id == "builtin", "retake same display") }
  else { check(false, "expected retake after error") }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
