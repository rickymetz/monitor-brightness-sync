import Cocoa

/// A small auto-dismissing message overlay (capsule, top-center), styled like
/// the system bezel. Used for hints — e.g. explaining why the brightness keys
/// do nothing when every monitor is turned off.
final class MessageHUD {
  private let height: CGFloat = 46
  private var window: NSWindow?
  private var builtWidth: CGFloat = 0
  private let label = NSTextField(labelWithString: "")
  private var hideWorkItem: DispatchWorkItem?
  private var generation = 0

  func show(_ message: String, on screen: NSScreen? = nil) {
    label.stringValue = message
    label.sizeToFit()
    let width = min(480, max(220, label.frame.width + 48))

    let window = windowIfNeeded(width: width)
    if let vf = (screen ?? NSScreen.main)?.visibleFrame {
      window.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - height - 12))
    }

    generation += 1
    let token = generation
    hideWorkItem?.cancel()
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
  }

  /// Build (or rebuild on a width change) the capsule window sized to the text.
  private func windowIfNeeded(width: CGFloat) -> NSWindow {
    if let window, abs(builtWidth - width) < 0.5 { return window }
    window?.orderOut(nil)

    let size = NSSize(width: width, height: height)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true // float the panel so the glass reads with depth
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    let labelHeight = label.fittingSize.height
    label.frame = NSRect(x: 24, y: (height - labelHeight) / 2, width: width - 48, height: labelHeight)

    let content = NSView(frame: NSRect(origin: .zero, size: size))
    content.addSubview(label)
    window.contentView = OverlayMaterial.container(size: size, cornerRadius: height / 2, wrapping: content)

    self.window = window
    self.builtWidth = width
    return window
  }
}
