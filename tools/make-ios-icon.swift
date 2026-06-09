// Generates a full-bleed, opaque 1024 iOS app icon matching the Mac icon
// (white sun on a warm yellow→orange gradient; iOS applies the rounded mask).
// Run: swift tools/make-ios-icon.swift <output.png>
import AppKit
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let topColor = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.25, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.96, green: 0.49, blue: 0.13, alpha: 1)

func drawSun(center c: NSPoint, scale s: CGFloat) {
  NSColor.white.set()
  let discR = s * 0.135
  NSBezierPath(ovalIn: NSRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2)).fill()
  let ri = s * 0.22, ro = s * 0.31, lw = s * 0.05
  for i in 0 ..< 8 {
    let a = CGFloat(i) / 8 * 2 * .pi
    let path = NSBezierPath()
    path.move(to: NSPoint(x: c.x + cos(a) * ri, y: c.y + sin(a) * ri))
    path.line(to: NSPoint(x: c.x + cos(a) * ro, y: c.y + sin(a) * ro))
    path.lineWidth = lw; path.lineCapStyle = .round; path.stroke()
  }
}

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                          bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                          isPlanar: false, colorSpaceName: .deviceRGB,
                          bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(px)
NSGradient(starting: topColor, ending: bottomColor)!.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)
drawSun(center: NSPoint(x: s / 2, y: s / 2), scale: s)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
