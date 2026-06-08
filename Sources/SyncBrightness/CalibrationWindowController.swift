import Cocoa

private final class CalFlippedView: NSView {
  override var isFlipped: Bool { true }
}

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
  private let builtinLabel = NSTextField(labelWithString: "--%")
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

  private let winW: CGFloat = 400
  private let margin: CGFloat = 20
  private var cardW: CGFloat { winW - 2 * margin }

  private func buildWindow() {
    let content = CalFlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 10))
    var y: CGFloat = 18

    // Header + instructions
    let title = NSTextField(labelWithString: "Calibrate displays")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.frame = NSRect(x: margin, y: y, width: cardW, height: 20)
    content.addSubview(title)
    y += 26

    let instructions = NSTextField(wrappingLabelWithString:
      "Pick a monitor, set your Mac brightness with the keyboard, then drag “External brightness” until that monitor looks the same and click Add point. Repeat at a few levels — each monitor is saved separately.")
    instructions.font = .systemFont(ofSize: 11)
    instructions.textColor = .secondaryLabelColor
    instructions.frame = NSRect(x: margin, y: y, width: cardW, height: 48)
    content.addSubview(instructions)
    y += 48 + 14

    // Match card: Monitor / Built-in / External brightness slider
    let rowH: CGFloat = 38
    let sliderRowH: CGFloat = 54
    let cardPad: CGFloat = 5
    let matchH = rowH * 2 + sliderRowH + 2 * cardPad
    let matchCard = styledCard(at: y, height: matchH)

    rowLabel(matchCard, "Monitor", top: cardPad, rowH: rowH)
    monitorPopup.target = self
    monitorPopup.action = #selector(monitorChanged)
    if displays.isEmpty {
      monitorPopup.addItem(withTitle: "No external display connected")
      monitorPopup.isEnabled = false
    } else {
      for display in displays { monitorPopup.addItem(withTitle: display.name) }
    }
    monitorPopup.frame = NSRect(x: cardW - 16 - 220, y: cardPad + (rowH - 25) / 2, width: 220, height: 25)
    matchCard.addSubview(monitorPopup)
    sep(matchCard, at: cardPad + rowH)

    rowLabel(matchCard, "Built-in brightness", top: cardPad + rowH, rowH: rowH)
    builtinLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    builtinLabel.textColor = .secondaryLabelColor
    builtinLabel.alignment = .right
    builtinLabel.frame = NSRect(x: cardW - 16 - 80, y: cardPad + rowH + (rowH - 17) / 2, width: 80, height: 17)
    matchCard.addSubview(builtinLabel)
    sep(matchCard, at: cardPad + rowH * 2)

    let extTop = cardPad + rowH * 2
    rowLabel(matchCard, "External brightness", top: extTop, rowH: 30)
    valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    valueLabel.alignment = .right
    valueLabel.textColor = .secondaryLabelColor
    valueLabel.frame = NSRect(x: cardW - 16 - 60, y: extTop + 7, width: 60, height: 17)
    matchCard.addSubview(valueLabel)
    slider.minValue = 0
    slider.maxValue = 100
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(sliderChanged(_:))
    slider.isEnabled = !displays.isEmpty
    slider.frame = NSRect(x: 16, y: extTop + 30, width: cardW - 32, height: 20)
    matchCard.addSubview(slider)
    content.addSubview(matchCard)
    y += matchH + 18

    // Saved points
    let header = NSTextField(labelWithString: "Saved points")
    header.font = .systemFont(ofSize: 12, weight: .semibold)
    header.textColor = .secondaryLabelColor
    header.frame = NSRect(x: margin + 4, y: y, width: cardW - 8, height: 16)
    content.addSubview(header)
    y += 16 + 6

    let listH: CGFloat = 92
    let listCard = styledCard(at: y, height: listH)
    let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: cardW - 16, height: listH - 16))
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    listView.frame = NSRect(x: 0, y: 0, width: cardW - 16, height: listH - 16)
    listView.isEditable = false
    listView.isSelectable = false
    listView.drawsBackground = false
    listView.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    listView.textContainerInset = NSSize(width: 4, height: 4)
    listView.minSize = NSSize(width: 0, height: 0)
    listView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    listView.isVerticallyResizable = true
    listView.isHorizontallyResizable = false
    listView.autoresizingMask = [.width]
    listView.textContainer?.containerSize = NSSize(width: cardW - 16, height: CGFloat.greatestFiniteMagnitude)
    listView.textContainer?.widthTracksTextView = true
    scroll.documentView = listView
    listCard.addSubview(scroll)
    content.addSubview(listCard)
    y += listH + 18

    // Footer
    let addButton = NSButton(title: "Add point", target: self, action: #selector(addPoint))
    addButton.bezelStyle = .rounded
    addButton.isEnabled = !displays.isEmpty
    addButton.keyEquivalent = "\r"
    addButton.frame = NSRect(x: margin, y: y, width: 110, height: 30)
    content.addSubview(addButton)
    let resetButton = NSButton(title: "Reset this monitor", target: self, action: #selector(resetMonitor))
    resetButton.bezelStyle = .rounded
    resetButton.isEnabled = !displays.isEmpty
    resetButton.frame = NSRect(x: margin + 118, y: y, width: 150, height: 30)
    content.addSubview(resetButton)
    let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
    doneButton.bezelStyle = .rounded
    doneButton.frame = NSRect(x: winW - margin - 70, y: y, width: 70, height: 30)
    content.addSubview(doneButton)
    y += 30 + 18

    content.frame = NSRect(x: 0, y: 0, width: winW, height: y)
    window = NSWindow(contentRect: content.frame,
                      styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
    window.title = "Calibrate"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentView = content
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.level = .floating
  }

  private func styledCard(at y: CGFloat, height: CGFloat) -> CalFlippedView {
    let card = CalFlippedView(frame: NSRect(x: margin, y: y, width: cardW, height: height))
    card.wantsLayer = true
    card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    card.layer?.cornerRadius = 10
    card.layer?.borderWidth = 0.5
    card.layer?.borderColor = NSColor.separatorColor.cgColor
    return card
  }

  private func rowLabel(_ card: NSView, _ text: String, top: CGFloat, rowH: CGFloat) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.frame = NSRect(x: 16, y: top + (rowH - 17) / 2, width: cardW - 120, height: 17)
    card.addSubview(label)
  }

  private func sep(_ card: NSView, at top: CGFloat) {
    let s = NSView(frame: NSRect(x: 16, y: top, width: cardW - 16, height: 1))
    s.wantsLayer = true
    s.layer?.backgroundColor = NSColor.separatorColor.cgColor
    card.addSubview(s)
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
      builtinLabel.stringValue = String(format: "%d%%", Int((f * 100).rounded()))
    } else {
      builtinLabel.stringValue = "—"
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
