import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
  if !condition { failures += 1 }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

print("== pattern channel mapping ==")
let rggb = BayerPattern.rggb
check(rggb.channel(x: 0, y: 0) == 0, "RGGB (0,0) = R")
check(rggb.channel(x: 1, y: 0) == 1, "RGGB (1,0) = G")
check(rggb.channel(x: 0, y: 1) == 1, "RGGB (0,1) = G")
check(rggb.channel(x: 1, y: 1) == 2, "RGGB (1,1) = B")
check(BayerPattern.bggr.channel(x: 0, y: 0) == 2, "BGGR (0,0) = B")
check(BayerPattern.grbg.channel(x: 0, y: 0) == 1 && BayerPattern.grbg.channel(x: 1, y: 0) == 0, "GRBG top row G,R")
check(BayerPattern.gbrg.channel(x: 1, y: 1) == 1 && BayerPattern.gbrg.channel(x: 0, y: 1) == 0, "GBRG bottom row R,G")

// Build an N×N RGGB mosaic where every R site = r, G = g, B = b (raw 14-bit-ish
// scale with a black pedestal), then confirm we recover the normalized values.
func mosaic(_ n: Int, r: Double, g: Double, b: Double, pattern: BayerPattern = .rggb) -> [Double] {
  var px = [Double](repeating: 0, count: n * n)
  for y in 0..<n {
    for x in 0..<n {
      switch pattern.channel(x: x, y: y) {
      case 0: px[y * n + x] = r
      case 1: px[y * n + x] = g
      default: px[y * n + x] = b
      }
    }
  }
  return px
}

print("== flat-field recovery (black-level + white-level normalization) ==")
let black = 512.0, white = 16383.0
// raw values chosen so normalized R=0.25, G=0.50, B=0.80
let rRaw = black + 0.25 * (white - black)
let gRaw = black + 0.50 * (white - black)
let bRaw = black + 0.80 * (white - black)
let px = mosaic(64, r: rRaw, g: gRaw, b: bRaw)
guard let avg = BayerField.average(pixels: px, width: 64, height: 64, pattern: .rggb,
                                   blackLevel: black, whiteLevel: white, centerFraction: 0.6) else {
  print("  ✗ average returned nil"); exit(1)
}
check(approx(avg.r, 0.25, 1e-9), String(format: "R normalized to 0.25 (got %.6f)", avg.r))
check(approx(avg.g, 0.50, 1e-9), String(format: "G normalized to 0.50 (got %.6f)", avg.g))
check(approx(avg.b, 0.80, 1e-9), String(format: "B normalized to 0.80 (got %.6f)", avg.b))

print("== clamping & black frame ==")
let dark = BayerField.average(pixels: mosaic(32, r: black, g: black, b: black),
                              width: 32, height: 32, pattern: .rggb,
                              blackLevel: black, whiteLevel: white)!
check(dark.r == 0 && dark.g == 0 && dark.b == 0, "at black level → 0,0,0")
let over = BayerField.average(pixels: mosaic(32, r: white * 2, g: white * 2, b: white * 2),
                              width: 32, height: 32, pattern: .rggb,
                              blackLevel: black, whiteLevel: white)!
check(over.r == 1 && over.g == 1 && over.b == 1, "above white level clamps to 1")

print("== degenerate guards ==")
check(BayerField.average(pixels: [1, 2, 3], width: 1, height: 1, pattern: .rggb) == nil, "1×1 returns nil")
check(BayerField.average(pixels: px, width: 64, height: 64, pattern: .rggb,
                         blackLevel: 100, whiteLevel: 100) == nil, "zero span returns nil")

print("== green averages both sites ==")
// Make the two green sites differ; result should be their mean.
var split = mosaic(8, r: 1000, g: 0, b: 2000)
for y in 0..<8 {
  for x in 0..<8 where BayerPattern.rggb.channel(x: x, y: y) == 1 {
    // Gr sites (even row) = 4000, Gb sites (odd row) = 8000
    split[y * 8 + x] = (y & 1) == 0 ? 4000 : 8000
  }
}
let g = BayerField.average(pixels: split, width: 8, height: 8, pattern: .rggb,
                           blackLevel: 0, whiteLevel: 12000, centerFraction: 1.0)!
check(approx(g.g, 6000.0 / 12000.0, 1e-9), String(format: "Gr+Gb averaged (got %.4f, want 0.5)", g.g))

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
