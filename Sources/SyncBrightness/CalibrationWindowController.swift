import Cocoa

/// Window for building per-monitor match curves. Pick a monitor, set the Mac
/// brightness with the keyboard, drag the slider until the external looks the
/// same, and add a point. Each monitor keeps its own curve (profile).
final class CalibrationWindowController: NSObject, NSWindowDelegate {
  private let onSelectTarget: (String) -> Void
  private let onManualExternal: (Double) -> Void
  private let onCommit: ([String: BrightnessCurve]) -> Void

  private let displays: [DisplayInfo]
  private var workingCurves: [String: BrightnessCurve]
  private var selectedID: String?
  private let builtinID: CGDirectDisplayID?

  private var window: NSWindow!
  private let monitorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let builtinLabel = NSTextField(labelWithString: "Built-in: --%")
  private let valueLabel = NSTextField(labelWithString: "--%")
  private let slider = NSSlider()
  private let listView = NSTextView()
  private var timer: Timer?

  init(displays: [DisplayInfo],
       savedCurves: [String: BrightnessCurve],
       onSelectTarget: @escaping (String) -> Void,
       onManualExternal: @escaping (Double) -> Void,
       onCommit: @escaping ([String: BrightnessCurve]) -> Void) {
    self.displays = displays
    self.onSelectTarget = onSelectTarget
    self.onManualExternal = onManualExternal
    self.onCommit = onCommit
    self.builtinID = BuiltinBrightness.builtinDisplayID()

    var curves: [String: BrightnessCurve] = [:]
    for display in displays {
      curves[display.id] = savedCurves[display.id] ?? .default
    }
    self.workingCurves = curves
    self.selectedID = displays.first?.id
    super.init()
    buildWindow()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)

    if let id = selectedID {
      onSelectTarget(id)
      applySliderToCurrentMatch(id: id)
    }
    refreshList()
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.refreshBuiltinLabel()
    }
    refreshBuiltinLabel()
  }

  // MARK: - UI

  private func buildWindow() {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))

    let title = NSTextField(labelWithString: "Calibrate external to match built-in")
    title.font = .boldSystemFont(ofSize: 13)
    title.frame = NSRect(x: 20, y: 366, width: 340, height: 22)
    content.addSubview(title)

    let instructions = NSTextField(wrappingLabelWithString:
      "Pick a monitor, set your Mac brightness with the keyboard, drag the slider until that monitor looks the same, then click “Add point.” Repeat at a few levels. Each monitor is saved separately.")
    instructions.font = .systemFont(ofSize: 11)
    instructions.textColor = .secondaryLabelColor
    instructions.frame = NSRect(x: 20, y: 298, width: 340, height: 62)
    content.addSubview(instructions)

    let monitorTitle = NSTextField(labelWithString: "Monitor")
    monitorTitle.font = .systemFont(ofSize: 12)
    monitorTitle.frame = NSRect(x: 20, y: 270, width: 64, height: 20)
    content.addSubview(monitorTitle)

    monitorPopup.frame = NSRect(x: 86, y: 267, width: 274, height: 25)
    monitorPopup.target = self
    monitorPopup.action = #selector(monitorChanged)
    if displays.isEmpty {
      monitorPopup.addItem(withTitle: "No external display connected")
      monitorPopup.isEnabled = false
    } else {
      for display in displays { monitorPopup.addItem(withTitle: display.name) }
    }
    content.addSubview(monitorPopup)

    builtinLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    builtinLabel.frame = NSRect(x: 20, y: 238, width: 340, height: 20)
    content.addSubview(builtinLabel)

    let externalTitle = NSTextField(labelWithString: "External match")
    externalTitle.font = .systemFont(ofSize: 12)
    externalTitle.frame = NSRect(x: 20, y: 210, width: 200, height: 20)
    content.addSubview(externalTitle)

    valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    valueLabel.alignment = .right
    valueLabel.frame = NSRect(x: 300, y: 210, width: 60, height: 20)
    content.addSubview(valueLabel)

    slider.minValue = 0
    slider.maxValue = 100
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(sliderChanged(_:))
    slider.isEnabled = !displays.isEmpty
    slider.frame = NSRect(x: 20, y: 184, width: 340, height: 22)
    content.addSubview(slider)

    let addButton = NSButton(title: "Add point", target: self, action: #selector(addPoint))
    addButton.bezelStyle = .rounded
    addButton.isEnabled = !displays.isEmpty
    addButton.frame = NSRect(x: 20, y: 146, width: 120, height: 30)
    content.addSubview(addButton)

    let scroll = NSScrollView(frame: NSRect(x: 20, y: 54, width: 340, height: 84))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    listView.frame = NSRect(x: 0, y: 0, width: 340, height: 84)
    listView.isEditable = false
    listView.isSelectable = false
    listView.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    listView.textContainerInset = NSSize(width: 6, height: 6)
    listView.minSize = NSSize(width: 0, height: 0)
    listView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    listView.isVerticallyResizable = true
    listView.isHorizontallyResizable = false
    listView.autoresizingMask = [.width]
    listView.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
    listView.textContainer?.widthTracksTextView = true
    scroll.documentView = listView
    content.addSubview(scroll)

    let resetButton = NSButton(title: "Reset this monitor", target: self, action: #selector(resetMonitor))
    resetButton.bezelStyle = .rounded
    resetButton.isEnabled = !displays.isEmpty
    resetButton.frame = NSRect(x: 20, y: 14, width: 160, height: 30)
    content.addSubview(resetButton)

    let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.frame = NSRect(x: 290, y: 14, width: 70, height: 30)
    content.addSubview(doneButton)

    window = NSWindow(contentRect: content.frame,
                      styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
    window.title = "Calibrate"
    window.contentView = content
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.level = .floating
  }

  // MARK: - Actions

  @objc private func monitorChanged() {
    let index = monitorPopup.indexOfSelectedItem
    guard displays.indices.contains(index) else { return }
    let id = displays[index].id
    selectedID = id
    onSelectTarget(id)
    applySliderToCurrentMatch(id: id)
    refreshList()
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    valueLabel.stringValue = String(format: "%d%%", Int(sender.doubleValue.rounded()))
    onManualExternal(sender.doubleValue / 100)
  }

  @objc private func addPoint() {
    guard let id = selectedID, let builtin = builtinFraction() else { return }
    var curve = workingCurves[id] ?? .default
    curve.addOrUpdate(builtin: builtin, external: slider.doubleValue / 100)
    workingCurves[id] = curve
    refreshList()
  }

  @objc private func resetMonitor() {
    guard let id = selectedID else { return }
    workingCurves[id] = .default
    applySliderToCurrentMatch(id: id)
    refreshList()
  }

  @objc private func done() {
    window.close() // triggers windowWillClose -> commit
  }

  func windowWillClose(_ notification: Notification) {
    timer?.invalidate()
    timer = nil
    onCommit(workingCurves)
  }

  // MARK: - Helpers

  private func builtinFraction() -> Double? {
    guard let builtinID else { return nil }
    return BuiltinBrightness.fraction(of: builtinID)
  }

  /// Set the slider (and drive the external) to the saved match for the current
  /// built-in level on the given monitor.
  private func applySliderToCurrentMatch(id: String) {
    let curve = workingCurves[id] ?? .default
    let external = builtinFraction().map { curve.external(for: $0) } ?? 0.5
    slider.doubleValue = external * 100
    sliderChanged(slider)
  }

  private func refreshBuiltinLabel() {
    if let f = builtinFraction() {
      builtinLabel.stringValue = String(format: "Built-in: %d%%", Int((f * 100).rounded()))
    } else {
      builtinLabel.stringValue = "Built-in: unavailable"
    }
  }

  private func refreshList() {
    guard let id = selectedID, let curve = workingCurves[id] else {
      listView.string = ""
      return
    }
    if curve.points.isEmpty {
      listView.string = "No points — this monitor will mirror the built-in 1:1."
      return
    }
    listView.string = curve.points.map {
      String(format: "Built-in %3d%%  →  External %3d%%",
             Int(($0.builtin * 100).rounded()), Int(($0.external * 100).rounded()))
    }.joined(separator: "\n")
  }
}
