import CoreGraphics
import Foundation

/// Locates the patch card in a photo via four corner fiducials, maps the quad,
/// and samples each patch cell's median color. Pure (no Cocoa). Returns nil if
/// the four fiducials can't be found.
enum PatchCardAnalyzer {
  static func sample(image: CGImage) -> PatchSamples? {
    guard let px = Pixels(image),
          let tl = px.centroid(matching: (0, 1, 1)),   // cyan  (top-left in pixel space)
          let tr = px.centroid(matching: (1, 0, 1)),   // magenta (top-right in pixel space)
          let bl = px.centroid(matching: (1, 1, 0)),   // yellow (bottom-left in pixel space)
          let br = px.whiteCorner() else { return nil } // white (bottom-right in pixel space)

    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    // PatchCardLayout v is bottom-up (0=bottom, 1=top); Pixels is top-down (0=top).
    // tl/tr are at low pixel-y (image top = CG top), bl/br at high pixel-y (image bottom = CG bottom).
    // PatchCardLayout row 1 (top, high v) maps to low pixel-y => vv = 1-v flips correctly.
    func map(_ u: Double, _ v: Double) -> CGPoint {
      let vv = 1 - v
      let top = lerp(tl, tr, u), bottom = lerp(bl, br, u)
      return lerp(top, bottom, vv)
    }
    func patch(col: Int, row: Int) -> RGB {
      let c = PatchCardLayout.cellCenter(col: col, row: row)
      return px.median(around: map(c.x, c.y), radiusFraction: 0.03)
    }
    return PatchSamples(
      white:  patch(col: 0, row: 1),
      gray50: patch(col: 1, row: 1),
      gray25: patch(col: 2, row: 1),
      red:    patch(col: 0, row: 0),
      green:  patch(col: 1, row: 0),
      blue:   patch(col: 2, row: 0))
  }
}

private struct Pixels {
  let w: Int, h: Int, data: [UInt8]
  init?(_ image: CGImage) {
    let w = image.width, h = image.height
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
  func centroid(matching t: (Double, Double, Double)) -> CGPoint? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: 0, to: w, by: 2) {
        let c = rgb(x, y)
        let d = abs(c.r - t.0) + abs(c.g - t.1) + abs(c.b - t.2)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        if d < 0.5 && sat > 0.35 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 15 ? CGPoint(x: sx / n, y: sy / n) : nil
  }
  func whiteCorner() -> CGPoint? {
    // White fiducial is at CG-bottom-right. In a top-down pixel buffer that means
    // high pixel-y (y > h/2) and high pixel-x (x > w/2).
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: h / 2, to: h, by: 2) {
      for x in stride(from: w / 2, to: w, by: 2) {
        let c = rgb(x, y)
        let sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
        let lum = (c.r + c.g + c.b) / 3
        if lum > 0.85 && sat < 0.1 { sx += Double(x); sy += Double(y); n += 1 }
      }
    }
    return n > 15 ? CGPoint(x: sx / n, y: sy / n) : nil
  }
  func median(around p: CGPoint, radiusFraction: Double) -> RGB {
    let rad = max(2, Int(Double(min(w, h)) * radiusFraction))
    let cx = Int(p.x), cy = Int(p.y)
    var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
    for y in max(0, cy - rad)...min(h - 1, cy + rad) {
      for x in max(0, cx - rad)...min(w - 1, cx + rad) {
        let c = rgb(x, y); rs.append(c.r); gs.append(c.g); bs.append(c.b)
      }
    }
    func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    return RGB(r: med(rs), g: med(gs), b: med(bs))
  }
}
