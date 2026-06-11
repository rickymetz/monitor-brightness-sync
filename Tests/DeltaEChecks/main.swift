import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
  if !condition { failures += 1 }
}

// CIEDE2000 reference data from Sharma, Wu & Dalal (2005), "The CIEDE2000
// Color-Difference Formula" — the canonical test set every implementation must
// reproduce. (Lab1, Lab2, expected ΔE00).
let cases: [(Lab, Lab, Double)] = [
  (Lab(L: 50, a: 2.6772, b: -79.7751), Lab(L: 50, a: 0, b: -82.7485), 2.0425),
  (Lab(L: 50, a: 3.1571, b: -77.2803), Lab(L: 50, a: 0, b: -82.7485), 2.8615),
  (Lab(L: 50, a: 2.8361, b: -74.0200), Lab(L: 50, a: 0, b: -82.7485), 3.4412),
  (Lab(L: 50, a: -1.3802, b: -84.2814), Lab(L: 50, a: 0, b: -82.7485), 1.0000),
  (Lab(L: 50, a: -1.1848, b: -84.8006), Lab(L: 50, a: 0, b: -82.7485), 1.0000),
  (Lab(L: 50, a: -0.9009, b: -85.5211), Lab(L: 50, a: 0, b: -82.7485), 1.0000),
  (Lab(L: 50, a: 0, b: 0), Lab(L: 50, a: -1, b: 2), 2.3669),
  (Lab(L: 50, a: -1, b: 2), Lab(L: 50, a: 0, b: 0), 2.3669),
  (Lab(L: 50, a: 2.4900, b: -0.0010), Lab(L: 50, a: -2.4900, b: 0.0009), 7.1792),
  (Lab(L: 50, a: 2.5, b: 0), Lab(L: 50, a: 3.1736, b: 0.5854), 1.0000),
  (Lab(L: 50, a: 2.5, b: 0), Lab(L: 50, a: 3.2972, b: 0), 1.0000),
  (Lab(L: 50, a: 2.5, b: 0), Lab(L: 73, a: 25, b: -18), 27.1492),
  (Lab(L: 60.2574, a: -34.0099, b: 36.2677), Lab(L: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
  (Lab(L: 63.0109, a: -31.0961, b: -5.8663), Lab(L: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
  (Lab(L: 35.0831, a: -44.1164, b: 3.7933), Lab(L: 35.0232, a: -40.0716, b: 1.5901), 1.8645),
  (Lab(L: 22.7233, a: 20.0904, b: -46.6940), Lab(L: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
]

print("== ciede2000 reference pairs ==")
for (i, c) in cases.enumerated() {
  let got = DeltaE.ciede2000(c.0, c.1)
  check(abs(got - c.2) < 1e-4, String(format: "pair %d: ΔE00 %.4f (expected %.4f)", i, got, c.2))
}

print("== symmetry & identity ==")
let p = Lab(L: 40, a: 12, b: -7), q = Lab(L: 55, a: -3, b: 20)
check(abs(DeltaE.ciede2000(p, q) - DeltaE.ciede2000(q, p)) < 1e-9, "ΔE00 is symmetric")
check(DeltaE.ciede2000(p, p) == 0, "ΔE00(x,x) == 0")

print("== linear-RGB → Lab sanity ==")
// Linear sRGB white → L*≈100, a*≈0, b*≈0.
let white = DeltaE.lab(fromLinearRGB: RGB(r: 1, g: 1, b: 1))
check(abs(white.L - 100) < 0.01, String(format: "white L* ≈ 100 (got %.3f)", white.L))
check(abs(white.a) < 0.01 && abs(white.b) < 0.02, String(format: "white neutral a≈%.3f b≈%.3f", white.a, white.b))
// Black → L*=0.
let black = DeltaE.lab(fromLinearRGB: RGB(r: 0, g: 0, b: 0))
check(black.L == 0, "black L* == 0")
// A bluish cast vs neutral gray of equal luma is a non-trivial ΔE.
let neutral = RGB(r: 0.5, g: 0.5, b: 0.5)
let bluish = RGB(r: 0.45, g: 0.48, b: 0.6)
check(DeltaE.between(neutral, bluish) > 3, "bluish vs neutral is a visible ΔE")
check(DeltaE.between(neutral, neutral) == 0, "identical measurements → ΔE 0")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
