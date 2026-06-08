import Cocoa

/// Top-down layout helper (AppKit is bottom-up by default).
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A System Settings–style control window: grouped rounded cards, rows with a
/// label on the left and an NSSwitch/control on the right, section headers, and
/// hairline separators. Mirrors the menu-bar controls for users who hide the icon.
final class ControlWindowController: NSObject, NSWindowDelegate {
  var onSetSync: (Bool) -> Void = { _ in }
  var onSetDimming: (Bool) -> Void = { _ in }
  var onSetBlackout: (Bool) -> Void = { _ in }
  var onSetLoginItem: (Bool) -> Void = { _ in }
  var onSetKeyControl: (Bool) -> Void = { _ in }
  var onCalibrate: () -> Void = {}
  var onReset: () -> Void = {}
  var onClose: () -> Void = {}
  var onSetMonitorEnabled: (String, Bool) -> Void = { _, _ in }
  var onSetMonitorBrightness: (String, Double) -> Void = { _, _ in }
  var onSetHotkeysEnabled: (Bool) -> Void = { _ in }
  var onSetHotkeyUp: (KeyCombo?) -> Void = { _ in }
  var onSetHotkeyDown: (KeyCombo?) -> Void = { _ in }

  private(set) var window: NSWindow!

  // Layout metrics
  private let winW: CGFloat = 400
  private let margin: CGFloat = 20
  private var cardW: CGFloat { winW - 2 * margin }
  private let rowH: CGFloat = 38
  private let toggleRowH: CGFloat = 50
  private let cardPad: CGFloat = 5

  // Persistent controls (re-added on each rebuild, state preserved).
  private let statusLabel = NSTextField(labelWithString: "Starting…")
  private let syncSwitch = NSSwitch()
  private let dimmingSwitch = NSSwitch()
  private let blackoutSwitch = NSSwitch()
  private let keyControlSwitch = NSSwitch()
  private let loginSwitch = NSSwitch()
  private let hotkeysSwitch = NSSwitch()
  private let upRecorder = KeyRecorder()
  private let downRecorder = KeyRecorder()

  private var monitors: [MonitorState] = []
  private var rowIDs: [String] = []
  private var rowSwitches: [NSSwitch] = []
  private var rowSliders: [NSSlider] = []
  private var rowLabels: [NSTextField] = []

  override init() {
    super.init()
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: 480),
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
    window.title = "Monitor Brightness Sync"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.delegate = self

    syncSwitch.target = self; syncSwitch.action = #selector(toggleSync)
    dimmingSwitch.target = self; dimmingSwitch.action = #selector(toggleDimming)
    blackoutSwitch.target = self; blackoutSwitch.action = #selector(toggleBlackout)
    keyControlSwitch.target = self; keyControlSwitch.action = #selector(toggleKeyControl)
    loginSwitch.target = self; loginSwitch.action = #selector(toggleLogin)
    hotkeysSwitch.target = self; hotkeysSwitch.action = #selector(toggleHotkeys)
    upRecorder.onCapture = { [weak self] combo in self?.onSetHotkeyUp(combo) }
    downRecorder.onCapture = { [weak self] combo in self?.onSetHotkeyDown(combo) }
    rebuild()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func update(statusText: String, syncOn: Bool) {
    statusLabel.stringValue = statusText
    syncSwitch.state = syncOn ? .on : .off
  }

  func updateToggles(dimming: Bool, blackout: Bool, login: Bool, keyControl: Bool) {
    dimmingSwitch.state = dimming ? .on : .off
    blackoutSwitch.state = blackout ? .on : .off
    loginSwitch.state = login ? .on : .off
    keyControlSwitch.state = keyControl ? .on : .off
  }

  func updateHotkeys(enabled: Bool, up: KeyCombo, down: KeyCombo) {
    hotkeysSwitch.state = enabled ? .on : .off
    upRecorder.combo = up
    downRecorder.combo = down
    upRecorder.isEnabled = enabled
    downRecorder.isEnabled = enabled
  }

  func updateMonitors(_ monitors: [MonitorState]) {
    if monitors.map(\.id) == rowIDs, rowSwitches.count == monitors.count {
      self.monitors = monitors
      for (i, m) in monitors.enumerated() {
        rowSwitches[i].state = m.enabled ? .on : .off
        rowLabels[i].stringValue = m.healthy ? m.name : "⚠ \(m.name)"
        rowSliders[i].doubleValue = m.brightness * 100
      }
      return
    }
    self.monitors = monitors
    rebuild()
  }

  // MARK: - Layout

  private func rebuild() {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18

    // App header: icon + name + live status.
    let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 38, height: 38))
    let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
    icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(cfg)
    icon.contentTintColor = .systemYellow
    icon.setAccessibilityElement(false) // decorative; the name label conveys it
    content.addSubview(icon)
    let name = NSTextField(labelWithString: "Monitor Brightness Sync")
    name.font = .systemFont(ofSize: 15, weight: .semibold)
    name.frame = NSRect(x: margin + 50, y: y + 1, width: cardW - 50, height: 20)
    content.addSubview(name)
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.frame = NSRect(x: margin + 50, y: y + 21, width: cardW - 50, height: 16)
    content.addSubview(statusLabel)
    y += 38 + 18

    // Brightness sync card
    y = sectionHeader(content, y, "Brightness")
    y = toggleCard(content, y, [
      ("Sync external brightness", "Mirror the built-in display's brightness.", syncSwitch,
       "Mirror the built-in display's brightness onto your external monitors."),
      ("Allow extra-dark dimming", "Dim below the monitor's hardware minimum.", dimmingSwitch,
       "Dim the external below its hardware minimum to match the Mac at low brightness."),
      ("Allow dimming all the way to black", "Reach true black at the lowest brightness.", blackoutSwitch,
       "Let the external reach true black at the lowest brightness, like the Mac display."),
    ])
    y = caption(content, y, "Extra-dark dimming uses the display's color table — it can interact with Night Shift, True Tone, or f.lux at very low brightness.")

    // Monitors card
    y = sectionHeader(content, y, "Monitors")
    y = buildMonitorsCard(content, y)

    // General card
    y = sectionHeader(content, y, "General")
    y = toggleCard(content, y, [
      ("Use brightness keys with lid closed", "Drive the external when the lid is closed.", keyControlSwitch,
       "When the lid is closed, the brightness keys adjust the external monitor (needs Accessibility permission)."),
      ("Launch at login", "Open automatically when you log in.", loginSwitch,
       "Open Monitor Brightness Sync automatically when you log in."),
    ])

    // Keyboard shortcuts card
    y = sectionHeader(content, y, "Keyboard shortcuts")
    y = buildHotkeysCard(content, y)

    // Footer actions
    y += 6
    let calibrate = footerButton("Calibrate…", #selector(calibrate))
    calibrate.frame = NSRect(x: margin, y: y, width: 150, height: 30)
    content.addSubview(calibrate)
    let reset = footerButton("Reset calibration", #selector(reset))
    reset.frame = NSRect(x: margin + 158, y: y, width: 130, height: 30)
    content.addSubview(reset)
    let quit = footerButton("Quit", #selector(quit))
    quit.frame = NSRect(x: winW - margin - 64, y: y, width: 64, height: 30)
    content.addSubview(quit)
    y += 30 + 18

    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)

    // Cap the window to the screen and scroll if the content is taller, so cards
    // near the bottom (Keyboard shortcuts, footer) stay reachable on any display.
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: y))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = content
    window.contentView = scroll

    let maxH = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000) - 40
    window.setContentSize(NSSize(width: winW, height: min(y, maxH)))
    content.scroll(NSPoint(x: 0, y: 0)) // flipped doc: show the top
  }

  private func buildMonitorsCard(_ content: NSView, _ y: CGFloat) -> CGFloat {
    rowIDs = monitors.map(\.id)
    rowSwitches = []; rowSliders = []; rowLabels = []

    if monitors.isEmpty {
      return card(content, y, rowCount: 1) { card in
        let label = NSTextField(labelWithString: "No external display connected")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 16, y: (self.rowH - 17) / 2, width: self.cardW - 32, height: 17)
        card.addSubview(label)
      }
    }

    let blockH = rowH + 36 // name row + slider row
    let height = CGFloat(monitors.count) * blockH + 2 * cardPad
    let card = styledCard(at: y, height: height)
    for (index, monitor) in monitors.enumerated() {
      let top = cardPad + CGFloat(index) * blockH
      if index > 0 { separatorAbsolute(card, top) }

      // Name + enable switch
      let label = NSTextField(labelWithString: monitor.healthy ? monitor.name : "⚠ \(monitor.name)")
      label.font = .systemFont(ofSize: 13)
      label.frame = NSRect(x: 16, y: top + (rowH - 17) / 2, width: cardW - 16 - 60, height: 17)
      card.addSubview(label)
      rowLabels.append(label)

      let sw = NSSwitch()
      sw.state = monitor.enabled ? .on : .off
      sw.tag = index
      sw.setAccessibilityLabel("Sync \(monitor.name)")
      sw.target = self; sw.action = #selector(monitorEnableChanged(_:))
      let sz = sw.fittingSize
      sw.frame = NSRect(x: cardW - 16 - sz.width, y: top + (rowH - sz.height) / 2, width: sz.width, height: sz.height)
      card.addSubview(sw)
      rowSwitches.append(sw)

      // Brightness slider with sun icons
      let sliderTop = top + rowH
      let dim = NSImageView(frame: NSRect(x: 16, y: sliderTop + 9, width: 14, height: 14))
      dim.image = NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)
      dim.contentTintColor = .tertiaryLabelColor
      dim.setAccessibilityElement(false) // decorative
      card.addSubview(dim)
      let bright = NSImageView(frame: NSRect(x: cardW - 16 - 16, y: sliderTop + 8, width: 16, height: 16))
      bright.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
      bright.contentTintColor = .tertiaryLabelColor
      bright.setAccessibilityElement(false) // decorative
      card.addSubview(bright)

      let slider = NSSlider(value: monitor.brightness * 100, minValue: 0, maxValue: 100,
                            target: self, action: #selector(monitorBrightnessChanged(_:)))
      slider.isContinuous = true
      slider.tag = index
      slider.setAccessibilityLabel("\(monitor.name) brightness")
      slider.toolTip = "Set \(monitor.name)'s brightness manually."
      slider.frame = NSRect(x: 38, y: sliderTop + 7, width: cardW - 38 - 40, height: 20)
      card.addSubview(slider)
      rowSliders.append(slider)
    }
    content.addSubview(card)
    return y + height + 18
  }

  private func buildHotkeysCard(_ content: NSView, _ y: CGFloat) -> CGFloat {
    let height = toggleRowH + 2 * rowH + 2 * cardPad
    let card = styledCard(at: y, height: height)

    placeToggle(card, top: cardPad, title: "Custom brightness shortcuts",
                subtitle: "Use your own keys to change brightness — handy on a keyboard without brightness keys.",
                control: hotkeysSwitch,
                tooltip: "Register global shortcuts that change brightness like the brightness keys do.")
    placeRecorder(card, top: cardPad + toggleRowH, title: "Brightness up", recorder: upRecorder)
    placeRecorder(card, top: cardPad + toggleRowH + rowH, title: "Brightness down", recorder: downRecorder)

    content.addSubview(card)
    return y + height + 18
  }

  private func placeRecorder(_ card: NSView, top: CGFloat, title: String, recorder: KeyRecorder) {
    separatorAbsolute(card, top)
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13)
    label.frame = NSRect(x: 16, y: top + (rowH - 17) / 2, width: cardW - 16 - 140, height: 17)
    card.addSubview(label)

    recorder.setAccessibilityLabel("\(title) shortcut")
    let w: CGFloat = 124
    recorder.frame = NSRect(x: cardW - 16 - w, y: top + (rowH - 24) / 2, width: w, height: 24)
    card.addSubview(recorder)
  }

  // MARK: - Card / row builders

  private func styledCard(at y: CGFloat, height: CGFloat) -> FlippedView {
    let card = FlippedView(frame: NSRect(x: margin, y: y, width: cardW, height: height))
    card.wantsLayer = true
    card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    card.layer?.cornerRadius = 10
    card.layer?.borderWidth = 0.5
    card.layer?.borderColor = NSColor.separatorColor.cgColor
    return card
  }

  private func card(_ content: NSView, _ y: CGFloat, rowCount: Int, build: (FlippedView) -> Void) -> CGFloat {
    let height = CGFloat(rowCount) * rowH + 2 * cardPad
    let card = styledCard(at: y, height: height)
    build(card)
    content.addSubview(card)
    return y + height + 18
  }

  /// A small wrapping caption (footnote) tucked under the preceding card.
  private func caption(_ content: NSView, _ y: CGFloat, _ text: String) -> CGFloat {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .tertiaryLabelColor
    let w = cardW - 8
    label.preferredMaxLayoutWidth = w
    label.frame.size.width = w
    let h = label.fittingSize.height
    label.frame = NSRect(x: margin + 4, y: y - 12, width: w, height: h)
    content.addSubview(label)
    return y - 12 + h + 14
  }

  private func sectionHeader(_ content: NSView, _ y: CGFloat, _ title: String) -> CGFloat {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: margin + 4, y: y, width: cardW - 8, height: 16)
    content.addSubview(label)
    return y + 16 + 6
  }

  /// A card of toggle rows, each with a title, gray subtitle, and a switch.
  private func toggleCard(_ content: NSView, _ y: CGFloat,
                          _ rows: [(title: String, subtitle: String, control: NSSwitch, tooltip: String)]) -> CGFloat {
    let height = CGFloat(rows.count) * toggleRowH + 2 * cardPad
    let card = styledCard(at: y, height: height)
    for (i, row) in rows.enumerated() {
      let top = cardPad + CGFloat(i) * toggleRowH
      if i > 0 { separatorAbsolute(card, top) }
      placeToggle(card, top: top, title: row.title, subtitle: row.subtitle, control: row.control, tooltip: row.tooltip)
    }
    content.addSubview(card)
    return y + height + 18
  }

  private func placeToggle(_ card: NSView, top: CGFloat, title: String, subtitle: String, control: NSSwitch, tooltip: String) {
    let size = control.fittingSize
    let textW = cardW - 16 - size.width - 28
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.toolTip = tooltip
    titleLabel.frame = NSRect(x: 16, y: top + 7, width: textW, height: 17)
    card.addSubview(titleLabel)

    let sub = NSTextField(labelWithString: subtitle)
    sub.font = .systemFont(ofSize: 11)
    sub.textColor = .secondaryLabelColor
    sub.lineBreakMode = .byTruncatingTail
    sub.frame = NSRect(x: 16, y: top + 26, width: textW, height: 15)
    card.addSubview(sub)

    control.toolTip = tooltip
    control.setAccessibilityLabel(title) // the title is a sibling label; bind it for VoiceOver
    control.frame = NSRect(x: cardW - 16 - size.width, y: top + (toggleRowH - size.height) / 2, width: size.width, height: size.height)
    card.addSubview(control)
  }

  private func separatorAbsolute(_ card: NSView, _ top: CGFloat) {
    let sep = NSView(frame: NSRect(x: 16, y: top, width: cardW - 16, height: 1))
    sep.wantsLayer = true
    sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
    card.addSubview(sep)
  }

  private func footerButton(_ title: String, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .rounded
    return b
  }

  // MARK: - Actions

  @objc private func toggleSync() { onSetSync(syncSwitch.state == .on) }
  @objc private func toggleDimming() { onSetDimming(dimmingSwitch.state == .on) }
  @objc private func toggleBlackout() { onSetBlackout(blackoutSwitch.state == .on) }
  @objc private func toggleLogin() { onSetLoginItem(loginSwitch.state == .on) }
  @objc private func toggleKeyControl() { onSetKeyControl(keyControlSwitch.state == .on) }
  @objc private func toggleHotkeys() { onSetHotkeysEnabled(hotkeysSwitch.state == .on) }
  @objc private func calibrate() { onCalibrate() }
  @objc private func reset() { onReset() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func monitorEnableChanged(_ sender: NSSwitch) {
    guard rowIDs.indices.contains(sender.tag) else { return }
    onSetMonitorEnabled(rowIDs[sender.tag], sender.state == .on)
  }

  @objc private func monitorBrightnessChanged(_ sender: NSSlider) {
    guard rowIDs.indices.contains(sender.tag) else { return }
    onSetMonitorBrightness(rowIDs[sender.tag], sender.doubleValue / 100)
  }

  func windowWillClose(_ notification: Notification) { onClose() }
}
