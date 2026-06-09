import Foundation

/// Compares two side-by-side measurements. Color sync corrects **chroma** only
/// (luminance-normalized) and leaves brightness to the brightness-sync feature, so
/// the verdict is chroma-based; the brightness difference is reported separately.
/// Shared by the Mac (verdict in the Color Sync window) and the iOS debug readout
/// so they always agree.
struct SideBySideMetric: Equatable {
  let chroma: Double      // sum of |luminance-normalized channel differences|
  let brightness: Double  // |luminance difference|

  var verdict: String {
    chroma < 0.03 ? "color matched ✓" : (chroma < 0.07 ? "color close" : "color still off")
  }

  static func compare(_ a: RGB, _ b: RGB) -> SideBySideMetric {
    func lum(_ c: RGB) -> Double { (c.r + c.g + c.b) / 3 }
    func norm(_ c: RGB, _ l: Double) -> RGB { l > 1e-6 ? RGB(r: c.r / l, g: c.g / l, b: c.b / l) : c }
    let la = lum(a), lb = lum(b)
    let na = norm(a, la), nb = norm(b, lb)
    let chroma = abs(na.r - nb.r) + abs(na.g - nb.g) + abs(na.b - nb.b)
    return SideBySideMetric(chroma: chroma, brightness: abs(la - lb))
  }
}
