import Cocoa

/// A small window that mirrors the menu-bar controls, plus a per-monitor
/// section (enable + manual brightness). For users who hide the menu-bar icon.
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

  private(set) var window: NSWindow!
  private let statusLabel = NSTextField(labelWithString: "Starting…")
  private let syncCheckbox = NSButton(checkboxWithTitle: "Sync external brightness", target: nil, action: nil)
  private let dimmingCheckbox = NSButton(checkboxWithTitle: "Allow extra-dark dimming", target: nil, action: nil)
  private let blackoutCheckbox = NSButton(checkboxWithTitle: "Dim all the way to black", target: nil, action: nil)
  private let loginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
  private let keyControlCheckbox = NSButton(checkboxWithTitle: "Use brightness keys with lid closed", target: nil, action: nil)
  private var monitors: [MonitorState] = []
  private var rowIDs: [String] = []
  private var rowChecks: [NSButton] = []
  private var rowSliders: [NSSlider] = []

  override init() {
    super.init()
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
    window.title = "Monitor Brightness Sync"
    window.isReleasedWhenClosed = false
    window.delegate = self
    syncCheckbox.target = self
    syncCheckbox.action = #selector(toggleSync)
    dimmingCheckbox.target = self
    dimmingCheckbox.action = #selector(toggleDimming)
    dimmingCheckbox.toolTip = "Software-dims the external below its hardware minimum so it can match the Mac's darkness at low brightness."
    blackoutCheckbox.target = self
    blackoutCheckbox.action = #selector(toggleBlackout)
    blackoutCheckbox.toolTip = "At the lowest brightness, let the external go completely black, like the Mac display. Turns on extra-dark dimming."
    loginCheckbox.target = self
    loginCheckbox.action = #selector(toggleLogin)
    keyControlCheckbox.target = self
    keyControlCheckbox.action = #selector(toggleKeyControl)
    keyControlCheckbox.toolTip = "When the lid is closed, the brightness keys adjust the external monitor (needs Accessibility permission)."
    rebuild()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func update(statusText: String, syncOn: Bool) {
    statusLabel.stringValue = statusText
    syncCheckbox.state = syncOn ? .on : .off
  }

  /// Reflect the global toggle states (driven by the menu or settings).
  func updateToggles(dimming: Bool, blackout: Bool, login: Bool, keyControl: Bool) {
    dimmingCheckbox.state = dimming ? .on : .off
    blackoutCheckbox.state = blackout ? .on : .off
    loginCheckbox.state = login ? .on : .off
    keyControlCheckbox.state = keyControl ? .on : .off
  }

  func updateMonitors(_ monitors: [MonitorState]) {
    // Only rebuild the layout when the set of monitors changes; otherwise update
    // the existing controls in place so we don't destroy a slider mid-drag or
    // flicker on every brightness tick.
    if monitors.map(\.id) == rowIDs, rowChecks.count == monitors.count {
      self.monitors = monitors
      for (index, monitor) in monitors.enumerated() {
        rowChecks[index].state = monitor.enabled ? .on : .off
        rowChecks[index].title = monitor.healthy ? monitor.name : "⚠ \(monitor.name)"
        rowSliders[index].doubleValue = monitor.brightness * 100
      }
      return
    }
    self.monitors = monitors
    rebuild()
  }

  // MARK: - Layout (rebuilt whenever the monitor list changes)

  private func rebuild() {
    let width: CGFloat = 360
    let pad: CGFloat = 16
    let rowH: CGFloat = 30
    let gap: CGFloat = 10
    let listH: CGFloat = monitors.isEmpty ? 18 : CGFloat(monitors.count) * rowH
    // title + status + 5 toggle checkboxes + monitors header + rows + buttons
    let total = pad + 22 + 6 + 18 + gap + 24 + 6 + 24 + 6 + 24 + 6 + 24 + 6 + 24 + gap + 16 + 6 + listH + gap + 30 + 8 + 30 + pad

    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
    var y = total - pad

    // Title + icon
    y -= 22
    let icon = NSImageView(frame: NSRect(x: 20, y: y, width: 20, height: 20))
    icon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
    icon.contentTintColor = .secondaryLabelColor
    content.addSubview(icon)
    let title = NSTextField(labelWithString: "Monitor Brightness Sync")
    title.font = .boldSystemFont(ofSize: 13)
    title.frame = NSRect(x: 48, y: y, width: width - 68, height: 20)
    content.addSubview(title)

    // Status
    y -= 6 + 18
    statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.frame = NSRect(x: 20, y: y, width: width - 40, height: 18)
    content.addSubview(statusLabel)

    // Global toggles
    y -= gap + 24
    syncCheckbox.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
    content.addSubview(syncCheckbox)
    y -= 6 + 24
    dimmingCheckbox.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
    content.addSubview(dimmingCheckbox)
    y -= 6 + 24
    blackoutCheckbox.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
    content.addSubview(blackoutCheckbox)
    y -= 6 + 24
    keyControlCheckbox.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
    content.addSubview(keyControlCheckbox)
    y -= 6 + 24
    loginCheckbox.frame = NSRect(x: 20, y: y, width: width - 40, height: 24)
    content.addSubview(loginCheckbox)

    // Monitors header
    y -= gap + 16
    let header = NSTextField(labelWithString: "Monitors")
    header.font = .systemFont(ofSize: 11, weight: .semibold)
    header.textColor = .secondaryLabelColor
    header.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
    content.addSubview(header)

    // Monitor rows
    y -= 6
    rowIDs = monitors.map(\.id)
    rowChecks = []
    rowSliders = []
    if monitors.isEmpty {
      y -= 18
      let none = NSTextField(labelWithString: "No external display connected")
      none.font = .systemFont(ofSize: 11)
      none.textColor = .tertiaryLabelColor
      none.frame = NSRect(x: 20, y: y, width: width - 40, height: 18)
      content.addSubview(none)
    } else {
      for (index, monitor) in monitors.enumerated() {
        y -= rowH
        let label = monitor.healthy ? monitor.name : "⚠ \(monitor.name)"
        let check = NSButton(checkboxWithTitle: label, target: self, action: #selector(monitorEnableChanged(_:)))
        check.tag = index
        check.state = monitor.enabled ? .on : .off
        check.frame = NSRect(x: 20, y: y + 3, width: 180, height: 22)
        content.addSubview(check)
        rowChecks.append(check)

        let slider = NSSlider(value: monitor.brightness * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(monitorBrightnessChanged(_:)))
        slider.tag = index
        slider.isContinuous = true
        slider.frame = NSRect(x: 208, y: y + 5, width: 132, height: 20)
        content.addSubview(slider)
        rowSliders.append(slider)
      }
    }

    // Buttons
    y -= gap + 30
    let calibrate = NSButton(title: "Calibrate…", target: self, action: #selector(calibrate))
    calibrate.bezelStyle = .rounded
    calibrate.frame = NSRect(x: 20, y: y, width: width - 40, height: 30)
    content.addSubview(calibrate)

    y -= 8 + 30
    let reset = NSButton(title: "Reset connected monitor", target: self, action: #selector(reset))
    reset.bezelStyle = .rounded
    reset.frame = NSRect(x: 20, y: y, width: 210, height: 30)
    content.addSubview(reset)
    let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
    quit.bezelStyle = .rounded
    quit.frame = NSRect(x: 262, y: y, width: 82, height: 30)
    content.addSubview(quit)

    window.contentView = content
    window.setContentSize(content.frame.size)
  }

  // MARK: - Actions

  @objc private func toggleSync() { onSetSync(syncCheckbox.state == .on) }
  @objc private func toggleDimming() { onSetDimming(dimmingCheckbox.state == .on) }
  @objc private func toggleBlackout() { onSetBlackout(blackoutCheckbox.state == .on) }
  @objc private func toggleLogin() { onSetLoginItem(loginCheckbox.state == .on) }
  @objc private func toggleKeyControl() { onSetKeyControl(keyControlCheckbox.state == .on) }
  @objc private func calibrate() { onCalibrate() }
  @objc private func reset() { onReset() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func monitorEnableChanged(_ sender: NSButton) {
    guard rowIDs.indices.contains(sender.tag) else { return }
    onSetMonitorEnabled(rowIDs[sender.tag], sender.state == .on)
  }

  @objc private func monitorBrightnessChanged(_ sender: NSSlider) {
    guard rowIDs.indices.contains(sender.tag) else { return }
    onSetMonitorBrightness(rowIDs[sender.tag], sender.doubleValue / 100)
  }

  func windowWillClose(_ notification: Notification) { onClose() }
}
