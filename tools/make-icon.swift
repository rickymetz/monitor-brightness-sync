// Generates AppIcon.iconset PNGs (sun on a warm gradient squircle).
// Run: swift tools/make-icon.swift <output-iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let topColor = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.25, alpha: 1) // warm yellow
let bottomColor = NSColor(srgbRed: 0.96, green: 0.49, blue: 0.13, alpha: 1) // orange

func drawSun(center c: NSPoint, scale s: CGFloat) {
  NSColor.white.set()
  let discR = s * 0.135
  NSBezierPath(ovalIn: NSRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2)).fill()
  let ri = s * 0.22, ro = s * 0.31, lw = s * 0.05
  let rays = 8
  for i in 0 ..< rays {
    let a = CGFloat(i) / CGFloat(rays) * 2 * .pi
    let path = NSBezierPath()
    path.move(to: NSPoint(x: c.x + cos(a) * ri, y: c.y + sin(a) * ri))
    path.line(to: NSPoint(x: c.x + cos(a) * ro, y: c.y + sin(a) * ro))
    path.lineWidth = lw
    path.lineCapStyle = .round
    path.stroke()
  }
}

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  let s = CGFloat(px)
  let pad = s * 0.085
  let rect = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
  let radius = rect.width * 0.2237
  let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  NSGradient(starting: topColor, ending: bottomColor)!.draw(in: squircle, angle: -90)
  drawSun(center: NSPoint(x: s / 2, y: s / 2), scale: s)

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let variants: [(Int, String)] = [
  (16, "icon_16x16"), (32, "icon_16x16@2x"),
  (32, "icon_32x32"), (64, "icon_32x32@2x"),
  (128, "icon_128x128"), (256, "icon_128x128@2x"),
  (256, "icon_256x256"), (512, "icon_256x256@2x"),
  (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in variants {
  let data = render(px)
  try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(variants.count) icon PNGs to \(outDir)")
