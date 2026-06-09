import CoreGraphics
import Foundation

/// Result of measuring a fullscreen color field from a camera frame.
struct FieldMeasure: Equatable {
  let average: RGB        // mean color of the central region (camera space)
  let uniformBright: Bool // central region is a reasonably bright, uniform field
}

/// Measures a roughly-uniform color field (a fullscreen neutral shown on a
/// display) from a camera frame. With the camera locked, the average of the
/// central region IS the display's neutral chroma — no patch-card detection
/// needed. `uniformBright` is an easy, robust auto-capture gate: it's true when
/// the user has filled the frame with the (bright, even) display.
enum FieldSampler {
  static func measure(image: CGImage,
                      centerFraction: Double = 0.6,
                      minMeanLuma: Double = 0.20,
                      maxLumaStdDev: Double = 0.16) -> FieldMeasure {
    guard let px = FieldPixels(image) else {
      return FieldMeasure(average: RGB(r: 0, g: 0, b: 0), uniformBright: false)
    }
    let cf = max(0.1, min(1.0, centerFraction))
    let x0 = Int(Double(px.w) * (1 - cf) / 2), x1 = Int(Double(px.w) * (1 + cf) / 2)
    let y0 = Int(Double(px.h) * (1 - cf) / 2), y1 = Int(Double(px.h) * (1 + cf) / 2)
    var sr = 0.0, sg = 0.0, sb = 0.0, sl = 0.0, sll = 0.0, n = 0.0
    var y = y0
    while y < y1 {
      var x = x0
      while x < x1 {
        let c = px.rgb(x, y)
        sr += c.r; sg += c.g; sb += c.b
        let l = (c.r + c.g + c.b) / 3
        sl += l; sll += l * l; n += 1
        x += 2
      }
      y += 2
    }
    guard n > 0 else { return FieldMeasure(average: RGB(r: 0, g: 0, b: 0), uniformBright: false) }
    let avg = RGB(r: sr / n, g: sg / n, b: sb / n)
    let meanL = sl / n
    let stdL = max(0, sll / n - meanL * meanL).squareRoot()
    let uniform = meanL >= minMeanLuma && stdL <= maxLumaStdDev
    return FieldMeasure(average: avg, uniformBright: uniform)
  }
}

private struct FieldPixels {
  let w: Int, h: Int, data: [UInt8]
  init?(_ image: CGImage) {
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    self.w = w; self.h = h; self.data = buf
  }
  func rgb(_ x: Int, _ y: Int) -> RGB {
    let i = (y * w + x) * 4
    return RGB(r: Double(data[i]) / 255, g: Double(data[i+1]) / 255, b: Double(data[i+2]) / 255)
  }
}
