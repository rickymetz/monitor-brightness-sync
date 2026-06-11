import Foundation

/// Color-filter-array layout of a Bayer sensor, named by the 2×2 tile in
/// row-major order (top-left, top-right, bottom-left, bottom-right).
enum BayerPattern {
  case rggb, bggr, grbg, gbrg

  /// 0 = R, 1 = G, 2 = B for the mosaic cell at (x, y).
  func channel(x: Int, y: Int) -> Int {
    let tile: [Int]
    switch self {
    case .rggb: tile = [0, 1, 1, 2]
    case .bggr: tile = [2, 1, 1, 0]
    case .grbg: tile = [1, 0, 2, 1]
    case .gbrg: tile = [1, 2, 0, 1]
    }
    return tile[(y & 1) * 2 + (x & 1)]
  }
}

/// Pure reduction of a raw Bayer mosaic to one linear-RGB triple — the linear
/// replacement for averaging an 8-bit processed BGRA frame.
///
/// Why this matters: smartphone RAW is highly linear (R² ≈ 0.998) whereas the
/// processed/JPEG pipeline is not (~0.75–0.88), so for fitting channel ratios and
/// gamma against a self-emissive field the measurement must come from near-sensor
/// data. The platform layer captures non-ProRAW Bayer RAW and hands the planar
/// sensor samples here; this stays Cocoa-free so it is unit-testable without a
/// device.
enum BayerField {
  /// Average a centered region of the mosaic into normalized linear RGB.
  /// - pixels: row-major sensor samples (length width*height). Any numeric scale;
  ///   `blackLevel`/`whiteLevel` define the normalization window.
  /// - blackLevel/whiteLevel: per-sensor levels from the capture metadata. The
  ///   result is (sample − black) / (white − black), clamped to 0…1.
  /// Returns nil if the geometry is degenerate or a channel had no samples.
  static func average(pixels: [Double], width: Int, height: Int,
                      pattern: BayerPattern,
                      blackLevel: Double = 0, whiteLevel: Double = 1,
                      centerFraction: Double = 0.6) -> RGB? {
    guard width > 1, height > 1, pixels.count >= width * height else { return nil }
    let span = whiteLevel - blackLevel
    guard span > 1e-9 else { return nil }

    let cf = max(0.05, min(1.0, centerFraction))
    let x0 = Int(Double(width) * (1 - cf) / 2), x1 = Int(Double(width) * (1 + cf) / 2)
    let y0 = Int(Double(height) * (1 - cf) / 2), y1 = Int(Double(height) * (1 + cf) / 2)

    var sum = [0.0, 0.0, 0.0]
    var cnt = [0.0, 0.0, 0.0]
    var y = y0
    while y < y1 {
      let row = y * width
      var x = x0
      while x < x1 {
        let v = (pixels[row + x] - blackLevel) / span
        let ch = pattern.channel(x: x, y: y)
        sum[ch] += max(0, min(1, v))
        cnt[ch] += 1
        x += 1
      }
      y += 1
    }
    guard cnt[0] > 0, cnt[1] > 0, cnt[2] > 0 else { return nil }
    // Two green sites per tile are averaged together into a single G value.
    return RGB(r: sum[0] / cnt[0], g: sum[1] / cnt[1], b: sum[2] / cnt[2])
  }
}
