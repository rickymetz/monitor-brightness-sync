// Generates a full-bleed, opaque 1024 iOS app icon matching the Mac icon
// (white sun on a warm yellow→orange gradient; iOS applies the rounded mask).
// Run: swift tools/make-ios-icon.swift <output.png>
//
// Uses CoreGraphics (not AppKit): an offscreen CGBitmapContext renders reliably
// from a plain `swift` script, whereas NSBitmapImageRep + NSGraphicsContext draws
// NOTHING headless and yields an all-black PNG. The context is opaque (no alpha),
// which is also exactly what App Store icons require.
import CoreGraphics
import ImageIO
import CoreFoundation
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let px = 1024
let s = CGFloat(px)
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
  fatalError("could not create bitmap context")
}

// Warm gradient (top → bottom). In CG y=0 is the bottom, so start at the top.
let top = CGColor(red: 1.00, green: 0.78, blue: 0.25, alpha: 1)
let bottom = CGColor(red: 0.96, green: 0.49, blue: 0.13, alpha: 1)
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// White sun: solid disc + 8 rays.
let c = CGPoint(x: s / 2, y: s / 2)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
ctx.setFillColor(white)
let discR = s * 0.135
ctx.fillEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))

let ri = s * 0.22, ro = s * 0.31
ctx.setStrokeColor(white)
ctx.setLineWidth(s * 0.05)
ctx.setLineCap(.round)
for i in 0 ..< 8 {
  let a = CGFloat(i) / 8 * 2 * .pi
  ctx.move(to: CGPoint(x: c.x + cos(a) * ri, y: c.y + sin(a) * ri))
  ctx.addLine(to: CGPoint(x: c.x + cos(a) * ro, y: c.y + sin(a) * ro))
}
ctx.strokePath()

guard let img = ctx.makeImage() else { fatalError("could not render image") }
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
  fatalError("could not create PNG destination")
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
print("wrote \(outPath)")
