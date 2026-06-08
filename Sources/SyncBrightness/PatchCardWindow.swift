import Cocoa

final class PatchCardWindow {
  private var window: NSWindow?

  enum Content { case midGray, patchCard }

  func show(_ content: Content, on screen: NSScreen) {
    let w = window ?? makeWindow(on: screen)
    w.setFrame(screen.frame, display: true)
    (w.contentView as? PatchCardView)?.content = content
    w.contentView?.needsDisplay = true
    w.makeKeyAndOrderFront(nil)
    window = w
  }

  func hide() { window?.orderOut(nil); window = nil }

  private func makeWindow(on screen: NSScreen) -> NSWindow {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.isOpaque = true
    w.backgroundColor = .black
    w.contentView = PatchCardView(frame: screen.frame)
    return w
  }
}

private final class PatchCardView: NSView {
  var content: PatchCardWindow.Content = .patchCard

  override func draw(_ dirty: NSRect) {
    if content == .midGray {
      NSColor(white: 0.5, alpha: 1).setFill(); bounds.fill(); return
    }
    NSColor.black.setFill(); bounds.fill()
    let m: CGFloat = 64
    func box(_ r: NSRect, _ c: NSColor) { c.setFill(); r.fill() }
    box(NSRect(x: 0, y: bounds.maxY - m, width: m, height: m), .cyan)              // TL
    box(NSRect(x: bounds.maxX - m, y: bounds.maxY - m, width: m, height: m), .magenta) // TR
    box(NSRect(x: 0, y: 0, width: m, height: m), .yellow)                          // BL
    box(NSRect(x: bounds.maxX - m, y: 0, width: m, height: m), .white)             // BR
    for col in 0..<PatchCardLayout.columns {
      for row in 0..<PatchCardLayout.rows {
        let nr = PatchCardLayout.cellRect(col: col, row: row)
        let rect = NSRect(x: nr.minX * bounds.width, y: nr.minY * bounds.height,
                          width: nr.width * bounds.width, height: nr.height * bounds.height)
        let c = PatchCardLayout.fillColor(PatchCardLayout.role(col: col, row: row))
        box(rect, NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
      }
    }
  }
}
