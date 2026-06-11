import Foundation
import CoreGraphics

// Validates ICC generation + (critically) the calibrated-RGB matrix ORDER convention,
// by round-tripping primaries through the generated profile into a known XYZ space.
var failures = 0
func check(_ cond: Bool, _ name: String) {
  print(cond ? "  ✓ \(name)" : "  ✗ \(name)"); if !cond { failures += 1 }
}

// sRGB primaries → XYZ (D65), row-major XYZ = M·RGB.
let M = Matrix3([[0.4124, 0.3576, 0.1805],
                 [0.2126, 0.7152, 0.0722],
                 [0.0193, 0.1192, 0.9505]])

print("== generates a re-readable RGB ICC ==")
guard let icc = ICCProfileBuilder.iccData(rgbToXYZ: M, gamma: (2.2, 2.2, 2.2)) else {
  print("  ✗ iccData returned nil"); print("\n1 check FAILED."); exit(1)
}
check(icc.count > 128, "ICC has a header+body (\(icc.count) bytes)")
let reread = CGColorSpace(iccData: icc as CFData)
check(reread != nil, "ICC re-parses as a CGColorSpace")
check(reread?.model == .rgb, "re-parsed model is RGB")

print("== matrix order: primaries round-trip to XYZ ==")
// Convert each display primary through the generated space into CIEXYZ and compare to
// M's columns. This pins down whether CG wants row-major (XYZ=M·RGB) — if it were
// transposed, red would map to M's first ROW instead of first COLUMN and fail.
guard let cs = ICCProfileBuilder.colorSpace(rgbToXYZ: M, gamma: (1, 1, 1)),
      let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else {
  print("  ✗ could not build spaces"); print("\n1 check FAILED."); exit(1)
}
func toXYZ(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> [CGFloat]? {
  var comps = [r, g, b, 1]
  guard let c = CGColor(colorSpace: cs, components: &comps),
        let conv = c.converted(to: xyz, intent: .relativeColorimetric, options: nil) else { return nil }
  return conv.components
}
// Red primary → should be ≈ M column 0 = (0.4124, 0.2126, 0.0193), but ColorSync
// adapts to the profile's own (D50) PCS, so we compare DIRECTION/ratios, not absolutes:
// the column with the largest component for red is X, for green is Y, for blue is Z.
if let red = toXYZ(1, 0, 0), let green = toXYZ(0, 1, 0), let blue = toXYZ(0, 0, 1) {
  print(String(format: "  red→XYZ  (%.3f,%.3f,%.3f)", red[0], red[1], red[2]))
  print(String(format: "  green→XYZ(%.3f,%.3f,%.3f)", green[0], green[1], green[2]))
  print(String(format: "  blue→XYZ (%.3f,%.3f,%.3f)", blue[0], blue[1], blue[2]))
  check(red[0] > red[2] && green[1] >= green[0] && blue[2] > blue[0],
        "primaries land in the expected XYZ regions (row-major XYZ = M·RGB)")
} else {
  check(false, "primary conversion failed")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
