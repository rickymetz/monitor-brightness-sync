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

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
