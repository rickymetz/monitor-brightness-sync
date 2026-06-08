import Cocoa

/// A lookalike of the system brightness overlay (the native one can't be shown
/// by third-party apps). Matches the OS's style: macOS 26+ uses a top-right
/// pill with the display name and a 🔅──bar──🔆 row; earlier macOS uses the
/// classic centered-bottom square bezel with a sun icon and a 16-segment bar.
/// Shown when we drive the external directly in clamshell/external-only mode.
final class BrightnessHUD {
  private enum Style { case pill, classic }

  private let style: Style
  private let size: NSSize
  private var window: NSWindow?
  private let titleLabel = NSTextField(labelWithString: "")
  private let levelBar = LevelBar()
  private let segmentBar = SegmentedBar()
  private var hideWorkItem: DispatchWorkItem?
  private var generation = 0 // bumped each show; guards stale fade-outs

  init() {
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
      style = .pill
      size = NSSize(width: 320, height: 58)
    } else {
      style = .classic
      size = NSSize(width: 200, height: 200)
    }
  }

  func show(level: Double, name: String, on screen: NSScreen? = nil) {
    let window = windowIfNeeded()
    let clamped = max(0, min(1, level))
    switch style {
    case .pill:
      titleLabel.stringValue = name
      levelBar.level = clamped
    case .classic:
      segmentBar.filled = Int((clamped * Double(segmentBar.total)).rounded())
    }

    position(window, on: screen)
    OverlayMaterial.announce("\(name) brightness \(Int((clamped * 100).rounded())) percent")

    generation += 1
    let token = generation
    hideWorkItem?.cancel()

    // Fade in only when actually hidden; if it's already up (or mid fade-out),
    // animate back to full so rapid presses don't flash to invisible.
    if !window.isVisible {
      window.alphaValue = 0
      window.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = window.alphaValue < 1 ? 0.12 : 0
      window.animator().alphaValue = 1
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token, let window = self.window else { return }
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.3
        window.animator().alphaValue = 0
      }, completionHandler: { [weak self] in
        if self?.generation == token { window.orderOut(nil) }
      })
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
  }

  private func position(_ window: NSWindow, on screen: NSScreen?) {
    let target = screen ?? NSScreen.main
    switch style {
    case .pill:
      guard let vf = target?.visibleFrame else { return }
      window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10))
    case .classic:
      guard let frame = target?.frame else { return }
      window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.10))
    }
  }

  private func windowIfNeeded() -> NSWindow {
    if let window { return window }

    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true // float the panel so the glass reads with depth
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    let content = NSView(frame: NSRect(origin: .zero, size: size))
    switch style {
    case .pill: buildPill(in: content)
    case .classic: buildClassic(in: content)
    }

    window.contentView = materialContainer(wrapping: content)
    self.window = window
    return window
  }

  private func materialContainer(wrapping content: NSView) -> NSView {
    OverlayMaterial.container(size: size, cornerRadius: style == .pill ? 16 : 18, wrapping: content)
  }

  private func buildPill(in container: NSView) {
    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = .white
    titleLabel.alignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.frame = NSRect(x: 16, y: 33, width: size.width - 32, height: 16)
    container.addSubview(titleLabel)

    container.addSubview(sunIcon("sun.min.fill", NSRect(x: 16, y: 13, width: 16, height: 16)))
    container.addSubview(sunIcon("sun.max.fill", NSRect(x: size.width - 16 - 19, y: 12, width: 19, height: 19)))

    levelBar.frame = NSRect(x: 42, y: 20, width: size.width - 42 - 46, height: 4)
    container.addSubview(levelBar)
  }

  private func buildClassic(in container: NSView) {
    container.addSubview(sunIcon("sun.max.fill", NSRect(x: 64, y: 82, width: 72, height: 72), pointSize: 56))
    segmentBar.frame = NSRect(x: 26, y: 46, width: 148, height: 8)
    container.addSubview(segmentBar)
  }

  private func sunIcon(_ name: String, _ frame: NSRect, pointSize: CGFloat? = nil) -> NSImageView {
    let view = NSImageView(frame: frame)
    var image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    if let pointSize {
      image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }
    view.image = image
    view.contentTintColor = .white
    return view
  }
}

/// A continuous brightness track (dim) with a white filled portion (macOS 26 pill).
private final class LevelBar: NSView {
  var level: Double = 0 { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.white.withAlphaComponent(0.2).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    let filledWidth = max(bounds.height, bounds.width * CGFloat(max(0, min(1, level))))
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: filledWidth, height: bounds.height),
                 xRadius: radius, yRadius: radius).fill()
  }
}

/// A 16-segment brightness bar like the classic (pre-26) bezel's.
private final class SegmentedBar: NSView {
  let total = 16
  var filled = 0 { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let gap: CGFloat = 2
    let segW = (bounds.width - gap * CGFloat(total - 1)) / CGFloat(total)
    let radius = min(segW, bounds.height) * 0.35
    for i in 0 ..< total {
      let rect = NSRect(x: CGFloat(i) * (segW + gap), y: 0, width: segW, height: bounds.height)
      (i < filled ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
  }
}
