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

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
