import Foundation

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
  check(approx(out2["ext"]!.blueGain, c.blueGain), "locked G cancels (blue)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
