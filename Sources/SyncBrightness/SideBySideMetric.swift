import Foundation

/// Compares two side-by-side measurements. Color sync now matches BOTH chroma and
/// luminance (every display is driven to a common white), so the verdict is the
/// full CIEDE2000 — which folds in the brightness difference. `chromaOnly` and
/// `brightness` are kept as separate diagnostics. Shared by the Mac (verdict in
/// the Color Sync window) and the iOS debug readout so they always agree.
struct SideBySideMetric: Equatable {
  let chroma: Double      // sum of |luminance-normalized channel differences| (legacy)
  let brightness: Double  // |luminance difference|
  let deltaE: Double      // full CIEDE2000 of the two colors (includes lightness)
  let chromaOnly: Double  // CIEDE2000 with luminance equalized (hue/chroma only)

  /// Verdict on the full ΔE2000 (color + brightness). ~1 ΔE is a just-noticeable
  /// difference; <2 matched, <5 close.
  var verdict: String {
    deltaE < 2 ? "matched ✓" : (deltaE < 5 ? "close" : "still off")
  }

  static func compare(_ a: RGB, _ b: RGB) -> SideBySideMetric {
    func lum(_ c: RGB) -> Double { (c.r + c.g + c.b) / 3 }
    func norm(_ c: RGB, _ l: Double) -> RGB { l > 1e-6 ? RGB(r: c.r / l, g: c.g / l, b: c.b / l) : c }
    let la = lum(a), lb = lum(b)
    let na = norm(a, la), nb = norm(b, lb)
    let chroma = abs(na.r - nb.r) + abs(na.g - nb.g) + abs(na.b - nb.b)
    // Full perceptual distance — color + brightness, since we now match both.
    let dE = DeltaE.between(a, b)
    // Luminance-equalized distance isolates the chroma error (diagnostic).
    func atMid(_ c: RGB, _ l: Double) -> RGB { l > 1e-6 ? RGB(r: c.r * 0.5 / l, g: c.g * 0.5 / l, b: c.b * 0.5 / l) : c }
    let chromaE = DeltaE.between(atMid(a, la), atMid(b, lb))
    return SideBySideMetric(chroma: chroma, brightness: abs(la - lb), deltaE: dE, chromaOnly: chromaE)
  }
}
