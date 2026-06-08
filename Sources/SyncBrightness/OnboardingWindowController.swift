import Cocoa

/// Top-down layout helper (AppKit is bottom-up by default).
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A one-time welcome shown on first launch: what the app does, the DDC/CI
/// requirement, the optional Accessibility grant for lid-closed control, and the
/// Night Shift / True Tone interaction with software dimming. Styled to match the
/// control window (grouped rows, SF Symbols, transparent titlebar).
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  /// Called once when the window is dismissed (button or close box).
  var onFinished: () -> Void = {}

  private(set) var window: NSWindow!
  private var finished = false

  private let winW: CGFloat = 460
  private let margin: CGFloat = 24

  private struct Point { let symbol: String; let title: String; let detail: String }
  private let points: [Point] = [
    Point(symbol: "sun.max.fill",
          title: "One set of brightness keys",
          detail: "Your Mac's brightness keys control the built-in and external displays together, kept in sync."),
    Point(symbol: "display",
          title: "Needs DDC/CI",
          detail: "External monitors must support DDC/CI to be controlled. Most do — if yours shows a warning, enable DDC/CI in its on-screen menu. Monitors that can't be reached are dimmed in software instead."),
    Point(symbol: "keyboard",
          title: "Lid-closed control is optional",
          detail: "To use the brightness keys with the lid closed, turn on “Use brightness keys with lid closed” and grant Accessibility access when prompted."),
    Point(symbol: "circle.lefthalf.filled",
          title: "Works alongside Night Shift",
          detail: "Extra-dark dimming adjusts the display's color table, so it can interact with Night Shift, True Tone, or f.lux at very low brightness."),
  ]

  override init() {
    super.init()
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: 200),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Welcome to Monitor Brightness Sync"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    build()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func build() {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 22

    let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 44, height: 44))
    icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 36, weight: .regular))
    icon.contentTintColor = .systemYellow
    icon.setAccessibilityElement(false)
    content.addSubview(icon)

    let title = NSTextField(labelWithString: "Monitor Brightness Sync")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.frame = NSRect(x: margin + 58, y: y + 2, width: winW - margin - 58 - margin, height: 22)
    content.addSubview(title)
    let sub = NSTextField(labelWithString: "Keep your displays' brightness in step.")
    sub.font = .systemFont(ofSize: 12)
    sub.textColor = .secondaryLabelColor
    sub.frame = NSRect(x: margin + 58, y: y + 24, width: winW - margin - 58 - margin, height: 16)
    content.addSubview(sub)
    y += 44 + 22

    for point in points {
      y = addRow(point, to: content, y: y)
    }

    y += 6
    let button = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
    button.bezelStyle = .rounded
    button.keyEquivalent = "\r" // default button
    button.frame = NSRect(x: winW - margin - 130, y: y, width: 130, height: 32)
    content.addSubview(button)
    y += 32 + 22

    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    window.contentView = content
    window.setContentSize(NSSize(width: winW, height: y))
  }

  private func addRow(_ point: Point, to content: NSView, y: CGFloat) -> CGFloat {
    let textX = margin + 38
    let textW = winW - textX - margin

    let icon = NSImageView(frame: NSRect(x: margin, y: y + 1, width: 22, height: 22))
    icon.image = NSImage(systemSymbolName: point.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
    icon.contentTintColor = .controlAccentColor
    icon.setAccessibilityElement(false)
    content.addSubview(icon)

    let title = NSTextField(labelWithString: point.title)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.frame = NSRect(x: textX, y: y, width: textW, height: 17)
    content.addSubview(title)

    let detail = NSTextField(wrappingLabelWithString: point.detail)
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    detail.frame = NSRect(x: textX, y: y + 20, width: textW, height: 14)
    detail.preferredMaxLayoutWidth = textW
    detail.sizeToFit()
    detail.frame = NSRect(x: textX, y: y + 20, width: textW, height: detail.frame.height)
    content.addSubview(detail)

    return y + 20 + detail.frame.height + 16
  }

  @objc private func getStarted() { window.close() }

  func windowWillClose(_ notification: Notification) {
    guard !finished else { return }
    finished = true
    onFinished()
  }
}
