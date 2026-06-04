import Cocoa

/// A small on-screen brightness overlay, shown when we drive the external
/// directly in clamshell/external-only mode (macOS shows no HUD then).
final class BrightnessHUD {
  private var window: NSWindow?
  private let bar = NSProgressIndicator()
  private var hideWorkItem: DispatchWorkItem?

  func show(level: Double, on screen: NSScreen? = nil) {
    let window = windowIfNeeded()
    bar.doubleValue = max(0, min(1, level)) * 100

    let target = screen ?? NSScreen.main
    if let frame = target?.frame {
      let size = window.frame.size
      let x = frame.midX - size.width / 2
      let y = frame.minY + frame.height * 0.12
      window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    window.orderFrontRegardless()

    hideWorkItem?.cancel()
    let work = DispatchWorkItem { [weak window] in window?.orderOut(nil) }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
  }

  private func windowIfNeeded() -> NSWindow {
    if let window { return window }

    let size = NSSize(width: 200, height: 200)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    visual.material = .hudWindow
    visual.state = .active
    visual.wantsLayer = true
    visual.layer?.cornerRadius = 18
    visual.layer?.masksToBounds = true

    let icon = NSImageView(frame: NSRect(x: 70, y: 70, width: 60, height: 60))
    icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
    icon.contentTintColor = .white
    visual.addSubview(icon)

    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 100
    bar.controlSize = .regular
    bar.frame = NSRect(x: 28, y: 36, width: 144, height: 20)
    visual.addSubview(bar)

    window.contentView = visual
    self.window = window
    return window
  }
}
