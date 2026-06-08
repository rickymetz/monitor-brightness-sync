import Cocoa

/// A rounded translucent overlay container matching the OS bezel material:
/// Liquid Glass on macOS 26+, classic vibrancy otherwise. Shared by the
/// brightness overlay and the hint overlay.
enum OverlayMaterial {
  static func container(size: NSSize, cornerRadius: CGFloat, wrapping content: NSView) -> NSView {
    content.frame = NSRect(origin: .zero, size: size)
    content.autoresizingMask = [.width, .height]
    content.addSubview(specularRim(size: size, cornerRadius: cornerRadius)) // edge highlight, on top

    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
      glass.style = .regular // the material style with the reflective edge
      glass.cornerRadius = cornerRadius
      glass.contentView = content
      return glass
    }
    let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    visual.material = .hudWindow
    visual.state = .active
    visual.blendingMode = .behindWindow
    visual.wantsLayer = true
    visual.layer?.cornerRadius = cornerRadius
    visual.layer?.masksToBounds = true
    visual.addSubview(content)
    return visual
  }

  /// A thin specular edge highlight (brighter at the top, fading down) that
  /// approximates the Liquid Glass rim — NSGlassEffectView only renders it
  /// faintly in a borderless overlay, so we reinforce it.
  private static func specularRim(size: NSSize, cornerRadius: CGFloat) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]

    let gradient = CAGradientLayer()
    gradient.frame = view.bounds
    gradient.colors = [
      NSColor.white.withAlphaComponent(0.5).cgColor, // top edge
      NSColor.white.withAlphaComponent(0.04).cgColor, // bottom edge
    ]
    gradient.startPoint = CGPoint(x: 0.5, y: 1)
    gradient.endPoint = CGPoint(x: 0.5, y: 0)

    let mask = CAShapeLayer()
    mask.path = CGPath(roundedRect: view.bounds.insetBy(dx: 0.6, dy: 0.6),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    mask.fillColor = NSColor.clear.cgColor
    mask.strokeColor = NSColor.white.cgColor
    mask.lineWidth = 1
    gradient.mask = mask

    view.layer?.addSublayer(gradient)
    return view
  }
}
