// Generates a transparent-background white sun for the iOS launch screen
// (UILaunchScreen centers this over a solid LaunchBackground color).
// Run: swift tools/make-ios-launch-logo.swift <output.png> <pixelSize>
import CoreGraphics
import ImageIO
import CoreFoundation
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "launch-logo.png"
let px = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 540 : 540
let s = CGFloat(px)
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
  fatalError("could not create bitmap context")
}
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))   // transparent background

let c = CGPoint(x: s / 2, y: s / 2)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
ctx.setFillColor(white)
let discR = s * 0.20
ctx.fillEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))

let ri = s * 0.33, ro = s * 0.46
ctx.setStrokeColor(white)
ctx.setLineWidth(s * 0.075)
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
print("wrote \(outPath) (\(px)px)")
