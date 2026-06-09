import Cocoa

/// Top-down layout helper (AppKit is bottom-up by default).
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A System Settings–style control window: a toolbar of tabs (Displays, Dimming,
/// Shortcuts, General), each a pane of grouped rounded cards with label-left /
/// control-right rows. The first tab holds the essentials you need on launch —
/// live status, the Sync toggle, and your monitors. The menu bar keeps a synced
/// quick subset of these controls.
final class ControlWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
  var onSetSync: (Bool) -> Void = { _ in }
  var onSetDimming: (Bool) -> Void = { _ in }
  var onSetBlackout: (Bool) -> Void = { _ in }
  var onSetLoginItem: (Bool) -> Void = { _ in }
  var onSetKeyControl: (Bool) -> Void = { _ in }
  var onCalibrate: () -> Void = {}
  var onReset: () -> Void = {}
  var onColorSync: () -> Void = {}
  var onClose: () -> Void = {}
  var onSetMonitorEnabled: (String, Bool) -> Void = { _, _ in }
  var onSetMonitorBrightness: (String, Double) -> Void = { _, _ in }
  var onSetHotkeysEnabled: (Bool) -> Void = { _ in }
  var onSetHotkeyUp: (KeyCombo?) -> Void = { _ in }
  var onSetHotkeyDown: (KeyCombo?) -> Void = { _ in }

  private(set) var window: NSWindow!

  // Layout metrics
  private let winW: CGFloat = 420
  private let margin: CGFloat = 20
  private var cardW: CGFloat { winW - 2 * margin }
  private let rowH: CGFloat = 38
  private let toggleRowH: CGFloat = 50
  private let cardPad: CGFloat = 5

  // Persistent controls (re-added when a tab is built, state preserved).
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

  private enum Tab: String, CaseIterable {
    case displays, dimming, shortcuts, general
    var title: String {
      switch self {
      case .displays: return "Displays"
      case .dimming: return "Dimming"
      case .shortcuts: return "Shortcuts"
      case .general: return "General"
      }
    }
    var symbol: String {
      switch self {
      case .displays: return "display"
      case .dimming: return "circle.lefthalf.filled"
      case .shortcuts: return "keyboard"
      case .general: return "gearshape"
      }
    }
  }
  private var currentTab: Tab = .displays

  override init() {
    super.init()
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: 300),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Monitor Brightness Sync"
    window.isReleasedWhenClosed = false
    window.delegate = self

    let toolbar = NSToolbar(identifier: "controlTabs")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .preference

    syncSwitch.target = self; syncSwitch.action = #selector(toggleSync)
    dimmingSwitch.target = self; dimmingSwitch.action = #selector(toggleDimming)
    blackoutSwitch.target = self; blackoutSwitch.action = #selector(toggleBlackout)
    keyControlSwitch.target = self; keyControlSwitch.action = #selector(toggleKeyControl)
    loginSwitch.target = self; loginSwitch.action = #selector(toggleLogin)
    hotkeysSwitch.target = self; hotkeysSwitch.action = #selector(toggleHotkeys)
    upRecorder.onCapture = { [weak self] combo in self?.onSetHotkeyUp(combo) }
    downRecorder.onCapture = { [weak self] combo in self?.onSetHotkeyDown(combo) }

    selectTab(.displays, animate: false)
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: - External state updates (persistent controls hold state across tabs)

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
    let sameSet = monitors.map(\.id) == rowIDs && rowSwitches.count == monitors.count
    self.monitors = monitors
    if sameSet {
      // In place — don't rebuild, so an in-progress slider drag isn't interrupted.
      for (i, m) in monitors.enumerated() {
        rowSwitches[i].state = m.enabled ? .on : .off
        rowLabels[i].stringValue = m.healthy ? m.name : "⚠ \(m.name)"
        rowSliders[i].doubleValue = m.brightness * 100
      }
      return
    }
    rowIDs = monitors.map(\.id)
    if currentTab == .displays { setContent(displaysView(), animate: false) } // monitor set changed
  }

  // MARK: - Tabs

  private func selectTab(_ tab: Tab, animate: Bool) {
    currentTab = tab
    window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
    let view: NSView
    switch tab {
    case .displays: view = displaysView()
    case .dimming: view = dimmingView()
    case .shortcuts: view = shortcutsView()
    case .general: view = generalView()
    }
    setContent(view, animate: animate)
  }

  /// Install a pane, capping the window to the screen (scroll if a tall pane,
  /// e.g. many monitors, would overflow) and resizing from the top edge.
  private func setContent(_ view: NSView, animate: Bool) {
    let maxH = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000) - 140
    let h = min(view.frame.height, maxH)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: h))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = view
    window.contentView = scroll

    let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: winW, height: h))
    var frame = window.frame
    let top = frame.maxY
    frame.size = target.size
    frame.origin.y = top - target.height // keep the top edge fixed as it grows/shrinks
    window.setFrame(frame, display: true, animate: animate)
    view.scroll(NSPoint(x: 0, y: 0)) // flipped doc: show the top
  }

  // MARK: - Tab panes

  private func displaysView() -> NSView {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.frame = NSRect(x: margin + 4, y: y, width: cardW - 8, height: 16)
    content.addSubview(statusLabel)
    y += 16 + 12

    y = sectionHeader(content, y, "Sync")
    y = toggleCard(content, y, [
      ("Sync external brightness", "Mirror the built-in display's brightness.", syncSwitch,
       "Mirror the built-in display's brightness onto your external monitors."),
    ])

    y = sectionHeader(content, y, "Monitors")
    y = buildMonitorsCard(content, y)

    y += 2
    let calibrate = footerButton("Calibrate…", #selector(calibrate))
    calibrate.frame = NSRect(x: margin, y: y, width: 150, height: 30)
    content.addSubview(calibrate)
    let reset = footerButton("Reset calibration", #selector(reset))
    reset.frame = NSRect(x: margin + 158, y: y, width: 150, height: 30)
    content.addSubview(reset)
    y += 30 + 18

    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    return content
  }

  private func dimmingView() -> NSView {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18
    y = sectionHeader(content, y, "Dimming")
    y = toggleCard(content, y, [
      ("Allow extra-dark dimming", "Dim below the monitor's hardware minimum.", dimmingSwitch,
       "Dim the external below its hardware minimum to match the Mac at low brightness."),
      ("Allow dimming all the way to black", "Reach true black at the lowest brightness.", blackoutSwitch,
       "Let the external reach true black at the lowest brightness, like the Mac display."),
    ])
    y = caption(content, y, "Extra-dark dimming uses the display's color table — it can interact with Night Shift, True Tone, or f.lux at very low brightness.")
    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    return content
  }

  private func shortcutsView() -> NSView {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18
    y = sectionHeader(content, y, "Brightness keys")
    y = toggleCard(content, y, [
      ("Use brightness keys with lid closed", "Drive the external when the lid is closed.", keyControlSwitch,
       "When the lid is closed, the brightness keys adjust the external monitor (needs Accessibility permission)."),
    ])
    y = sectionHeader(content, y, "Custom shortcuts")
    y = buildHotkeysCard(content, y)
    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    return content
  }

  private func generalView() -> NSView {
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18
    y = sectionHeader(content, y, "General")
    y = toggleCard(content, y, [
      ("Launch at login", "Open automatically when you log in.", loginSwitch,
       "Open Monitor Brightness Sync automatically when you log in."),
    ])
    y += 2
    let colorSyncButton = footerButton("Color Sync (beta)…", #selector(colorSync))
    colorSyncButton.frame = NSRect(x: margin, y: y, width: 180, height: 30)
    content.addSubview(colorSyncButton)
    y += 30 + 10
    let quit = footerButton("Quit Monitor Brightness Sync", #selector(quit))
    quit.frame = NSRect(x: margin, y: y, width: 240, height: 30)
    content.addSubview(quit)
    y += 30 + 18
    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    return content
  }

  // MARK: - NSToolbarDelegate

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    guard let tab = Tab(rawValue: id.rawValue) else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = tab.title
    item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
    item.target = self
    item.action = #selector(tabClicked(_:))
    return item
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Tab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  @objc private func tabClicked(_ sender: NSToolbarItem) {
    if let tab = Tab(rawValue: sender.itemIdentifier.rawValue) { selectTab(tab, animate: true) }
  }

  // MARK: - Cards

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
    let subtitle = "Use your own keys to change brightness — handy on a keyboard without brightness keys."
    let toggleH = toggleRowHeight(subtitle: subtitle, control: hotkeysSwitch)
    let height = toggleH + 2 * rowH + 2 * cardPad
    let card = styledCard(at: y, height: height)

    placeToggle(card, top: cardPad, rowHeight: toggleH, title: "Custom brightness shortcuts",
                subtitle: subtitle, control: hotkeysSwitch,
                tooltip: "Register global shortcuts that change brightness like the brightness keys do.")
    placeRecorder(card, top: cardPad + toggleH, title: "Brightness up", recorder: upRecorder)
    placeRecorder(card, top: cardPad + toggleH + rowH, title: "Brightness down", recorder: downRecorder)

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

  /// A card of toggle rows, each with a title, gray subtitle, and a switch. Rows
  /// grow to fit a wrapped subtitle so long descriptions don't get clipped.
  private func toggleCard(_ content: NSView, _ y: CGFloat,
                          _ rows: [(title: String, subtitle: String, control: NSSwitch, tooltip: String)]) -> CGFloat {
    let heights = rows.map { toggleRowHeight(subtitle: $0.subtitle, control: $0.control) }
    let height = heights.reduce(0, +) + 2 * cardPad
    let card = styledCard(at: y, height: height)
    var top = cardPad
    for (i, row) in rows.enumerated() {
      if i > 0 { separatorAbsolute(card, top) }
      placeToggle(card, top: top, rowHeight: heights[i], title: row.title, subtitle: row.subtitle, control: row.control, tooltip: row.tooltip)
      top += heights[i]
    }
    content.addSubview(card)
    return y + height + 18
  }

  /// Height a toggle row needs: the title block plus the wrapped subtitle.
  private func toggleRowHeight(subtitle: String, control: NSSwitch) -> CGFloat {
    let textW = cardW - 16 - control.fittingSize.width - 28
    let subH = wrappedHeight(subtitle, font: .systemFont(ofSize: 11), width: textW)
    return max(toggleRowH, 26 + subH + 9) // title (top 7 + 17 + 2 gap) + subtitle + bottom pad
  }

  private func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.preferredMaxLayoutWidth = width
    label.frame.size.width = width
    return label.fittingSize.height
  }

  private func placeToggle(_ card: NSView, top: CGFloat, rowHeight: CGFloat, title: String, subtitle: String, control: NSSwitch, tooltip: String) {
    let size = control.fittingSize
    let textW = cardW - 16 - size.width - 28
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.toolTip = tooltip
    titleLabel.frame = NSRect(x: 16, y: top + 7, width: textW, height: 17)
    card.addSubview(titleLabel)

    let sub = NSTextField(wrappingLabelWithString: subtitle)
    sub.font = .systemFont(ofSize: 11)
    sub.textColor = .secondaryLabelColor
    sub.preferredMaxLayoutWidth = textW
    sub.frame.size.width = textW
    let subH = sub.fittingSize.height
    sub.frame = NSRect(x: 16, y: top + 26, width: textW, height: subH)
    card.addSubview(sub)

    control.toolTip = tooltip
    control.setAccessibilityLabel(title) // the title is a sibling label; bind it for VoiceOver
    control.frame = NSRect(x: cardW - 16 - size.width, y: top + (rowHeight - size.height) / 2, width: size.width, height: size.height)
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
  @objc private func colorSync() { onColorSync() }
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
