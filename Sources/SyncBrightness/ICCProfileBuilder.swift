import CoreGraphics
import Foundation

/// Builds an ICC display profile (matrix/TRC RGB) from an RGB→XYZ primaries matrix
/// and a per-channel display gamma, by way of CoreGraphics' calibrated-RGB color
/// space (which emits a standard, OS-accepted ICC). Installing this profile for a
/// display lets ColorSync render content so the display matches the reference panel
/// the matrix was derived against — the full 3×3 correction the diagonal gamma-table
/// path cannot express.
enum ICCProfileBuilder {
  /// CoreGraphics' calibrated-RGB matrix is row-major: XYZ = M · RGB (validated by a
  /// round-trip in ProfileICCChecks). White point is M·(1,1,1); black assumed 0.
  static func colorSpace(rgbToXYZ m: Matrix3,
                         gamma: (r: Double, g: Double, b: Double)) -> CGColorSpace? {
    let white = m * RGB(r: 1, g: 1, b: 1)
    var wp: [CGFloat] = [CGFloat(white.r), CGFloat(white.g), CGFloat(white.b)]
    var bp: [CGFloat] = [0, 0, 0]
    var gm: [CGFloat] = [CGFloat(max(0.01, gamma.r)), CGFloat(max(0.01, gamma.g)), CGFloat(max(0.01, gamma.b))]
    var mat: [CGFloat] = [
      CGFloat(m.m[0][0]), CGFloat(m.m[0][1]), CGFloat(m.m[0][2]),
      CGFloat(m.m[1][0]), CGFloat(m.m[1][1]), CGFloat(m.m[1][2]),
      CGFloat(m.m[2][0]), CGFloat(m.m[2][1]), CGFloat(m.m[2][2]),
    ]
    return CGColorSpace(calibratedRGBWhitePoint: &wp, blackPoint: &bp, gamma: &gm, matrix: &mat)
  }

  /// ICC bytes for the profile, ready to write to disk and hand to ColorSync.
  static func iccData(rgbToXYZ m: Matrix3,
                      gamma: (r: Double, g: Double, b: Double)) -> Data? {
    guard let cs = colorSpace(rgbToXYZ: m, gamma: gamma),
          let icc = cs.copyICCData() else { return nil }
    return icc as Data
  }
}
