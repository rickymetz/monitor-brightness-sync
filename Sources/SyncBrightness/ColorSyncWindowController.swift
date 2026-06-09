import Cocoa

final class ColorSyncWindowController: NSWindowController, NSWindowDelegate {
  /// (display id, NSScreen, label). Reference first (built-in when present).
  var displays: [(id: String, screen: NSScreen, label: String)] = []
  /// Apply a correction map LIVE without persisting (preview/fine-tune).
  var onPreview: (([String: ColorCorrection]) -> Void)?
  /// Persist (and apply) a correction map. Only called from the Save button.
  var onSave: (([String: ColorCorrection]) -> Void)?
  /// Fired when the window closes so the owner can drop its reference (re-entrancy).
  var onClose: (() -> Void)?
  private var didTearDown = false

  private let transport = ColorSyncTransport()
  private let card = PatchCardWindow()
  private var corrections: [String: ColorCorrection] = [:]
  private var tune: [String: (warmCool: Double, brightness: Double)] = [:]

  // Ramp-capture orchestration (Mac drives the levels; phone measures on request).
  private let rampLevels = ColorMatcher.rampLevels        // [0.25, 0.5, 0.8]
  private let lockLevel = 0.8                             // lock exposure on the brightest level
  private let settleDelay = 0.6                           // wait after showing a level before measuring
  private let darkDelay = 0.25                            // brief black flash between levels
  private var displayIndex = -1
  private var levelIndex = 0
  private var rampReadings: [RGB] = []
  private var collectedSamples: [String: PatchSamples] = [:]

  private let imageView = NSImageView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private var tuneStack: NSStackView?

  convenience init() {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Color Sync (beta)"
    self.init(window: w)
    w.delegate = self
    let stack = NSStackView(views: [statusLabel, imageView])
    stack.orientation = .vertical; stack.spacing = 16; stack.alignment = .centerX
    stack.translatesAutoresizingMaskIntoConstraints = false
    w.contentView?.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
      stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
    ])
  }

  func begin() {
    guard displays.first != nil else {
      statusLabel.stringValue = "No displays found."
      showWindow(nil); return
    }
    do {
      let info = try transport.start()
      let payload = ColorSyncQR.payload(host: info.host, port: info.port, psk: info.psk)
      imageView.image = ColorSyncQR.image(for: payload)
      statusLabel.stringValue = "Open Monitor Brightness Sync on your iPhone (same Wi-Fi) and scan this code."
    } catch {
      statusLabel.stringValue = "Could not start: \(error.localizedDescription)"
      showWindow(nil); return
    }
    transport.onReceive = { [weak self] msg in self?.handle(msg) }
    transport.onClientConnected = { [weak self] in self?.startLock() }
    showWindow(nil)
  }

  // MARK: - Ramp orchestration (Mac drives levels; phone measures on request)

  private var referenceID: String { displays.first?.id ?? "" }

  private func startLock() {
    guard let ref = displays.first, let screen = screen(for: ref.id) else { return }
    collectedSamples.removeAll()
    card.show(.solid(lockLevel), on: screen)
    statusLabel.stringValue = "Press your phone's camera to \(ref.label) and tap Lock & Start."
    transport.send(.prepareLock(referenceLabel: ref.label))
  }

  private func handle(_ message: PhoneToMac) {
    switch message {
    case .locked:
      promptDisplay(0)
    case .beginRamp(let id) where id == currentDisplayID:
      startRamp()
    case .measured(let level, let r, let g, let b) where level == levelIndex && displayIndex >= 0:
      rampReadings.append(RGB(r: r, g: g, b: b))
      levelIndex += 1
      if levelIndex < rampLevels.count { showLevelThenMeasure() } else { finishDisplay() }
    default:
      break
    }
  }

  private var currentDisplayID: String? {
    displayIndex >= 0 && displayIndex < displays.count ? displays[displayIndex].id : nil
  }

  private func promptDisplay(_ i: Int) {
    guard i < displays.count, let screen = screen(for: displays[i].id) else { return }
    displayIndex = i
    card.show(.solid(lockLevel), on: screen)
    statusLabel.stringValue = "Press your phone to \(displays[i].label) and tap Capture (hold it there)."
    transport.send(.capture(displayID: displays[i].id, label: displays[i].label))
  }

  private func startRamp() {
    levelIndex = 0
    rampReadings = []
    showLevelThenMeasure()
  }

  private func showLevelThenMeasure() {
    guard let screen = currentDisplayID.flatMap({ screen(for: $0) }) else { return }
    let level = rampLevels[levelIndex]
    // Brief black flash, then the level, then measure once it has settled.
    card.show(.dark, on: screen)
    DispatchQueue.main.asyncAfter(deadline: .now() + darkDelay) { [weak self] in
      guard let self else { return }
      self.card.show(.solid(level), on: screen)
      DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDelay) { [weak self] in
        guard let self, self.displayIndex >= 0 else { return }
        self.transport.send(.measure(level: self.levelIndex))
      }
    }
  }

  private func finishDisplay() {
    guard let id = currentDisplayID, rampReadings.count == rampLevels.count else { return }
    // rampLevels = [0.25, 0.5, 0.8] -> gray25, gray50, white(brightest).
    collectedSamples[id] = PatchSamples(white: rampReadings[2], gray50: rampReadings[1],
                                        gray25: rampReadings[0],
                                        red: rampReadings[2], green: rampReadings[2], blue: rampReadings[2])
    if displayIndex + 1 < displays.count { promptDisplay(displayIndex + 1) } else { finishAll() }
  }

  private func finishAll() {
    transport.send(.done)
    card.hide()
    displayIndex = -1
    let measurements = collectedSamples.map { DisplayMeasurement(displayID: $0.key, samples: $0.value) }
    corrections = ColorMatcher.corrections(measurements: measurements, referenceID: referenceID)
    onPreview?(corrections)
    presentFineTune()
    // Diagnostic readout: measured brightest-field RGB + gamma + gains per display.
    var lines = ["Measured (brightest field) → correction:"]
    for d in displays {
      if let w = collectedSamples[d.id]?.white {
        lines.append(String(format: "%@:  R %.3f  G %.3f  B %.3f", d.label, w.r, w.g, w.b))
      }
      if let c = corrections[d.id] {
        lines.append(String(format: "   → gains R %.2f G %.2f B %.2f  γ %.2f",
                            c.redGain, c.greenGain, c.blueGain, c.gamma))
      }
    }
    statusLabel.stringValue = lines.joined(separator: "\n")
  }

  private func presentFineTune() {
    statusLabel.stringValue = "Done — colors matched. Fine-tune below, then Save."
    imageView.image = nil

    // Remove any previous tune UI (e.g. if presentFineTune is called again)
    tuneStack?.removeFromSuperview()

    let nonRef = displays.dropFirst()
    guard !nonRef.isEmpty else { return }

    // Initialize tune state for each non-reference display
    for d in nonRef where tune[d.id] == nil {
      tune[d.id] = (warmCool: 0, brightness: 1)
    }

    var rows: [NSView] = []

    // Per-display slider rows
    for d in nonRef {
      let header = NSTextField(labelWithString: d.label)
      header.font = NSFont.boldSystemFont(ofSize: 12)

      // Warm/cool slider
      let warmLabel = NSTextField(labelWithString: "Warm ↔ Cool")
      warmLabel.font = NSFont.systemFont(ofSize: 11)
      let warmSlider = NSSlider(value: tune[d.id]?.warmCool ?? 0,
                                minValue: -1, maxValue: 1, target: self,
                                action: #selector(sliderChanged(_:)))
      warmSlider.tag = sliderTag(id: d.id, kind: 0)
      warmSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

      let warmRow = NSStackView(views: [warmLabel, warmSlider])
      warmRow.orientation = .horizontal
      warmRow.spacing = 8
      warmRow.alignment = .centerY

      // Brightness slider
      let brightLabel = NSTextField(labelWithString: "Brightness")
      brightLabel.font = NSFont.systemFont(ofSize: 11)
      let brightSlider = NSSlider(value: tune[d.id]?.brightness ?? 1,
                                  minValue: 0.5, maxValue: 1, target: self,
                                  action: #selector(sliderChanged(_:)))
      brightSlider.tag = sliderTag(id: d.id, kind: 1)
      brightSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

      let brightRow = NSStackView(views: [brightLabel, brightSlider])
      brightRow.orientation = .horizontal
      brightRow.spacing = 8
      brightRow.alignment = .centerY

      let displayStack = NSStackView(views: [header, warmRow, brightRow])
      displayStack.orientation = .vertical
      displayStack.spacing = 6
      displayStack.alignment = .leading

      rows.append(displayStack)
    }

    // Before/After checkbox
    let beforeAfter = NSButton(checkboxWithTitle: "Before (show uncorrected)", target: self,
                               action: #selector(beforeAfterToggled(_:)))
    rows.append(beforeAfter)

    // Save button
    let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveTapped(_:)))
    saveBtn.bezelStyle = .rounded
    saveBtn.keyEquivalent = "\r"
    rows.append(saveBtn)

    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false
    tuneStack = stack

    window?.contentView?.addSubview(stack)
    if let contentView = window?.contentView {
      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
        stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
      ])
    }

    // Apply current state immediately as a preview (not persisted until Save)
    onPreview?(adjustedMap())
  }

  // MARK: - Slider tags (encode display index + kind into an Int)
  // kind 0 = warmCool, kind 1 = brightness
  private var sliderDisplayIDs: [Int: String] = [:]
  private var sliderKinds: [Int: Int] = [:]
  private var nextSliderTag = 100

  private func sliderTag(id: String, kind: Int) -> Int {
    let tag = nextSliderTag
    sliderDisplayIDs[tag] = id
    sliderKinds[tag] = kind
    nextSliderTag += 1
    return tag
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    guard let id = sliderDisplayIDs[sender.tag],
          let kind = sliderKinds[sender.tag] else { return }
    var t = tune[id] ?? (warmCool: 0, brightness: 1)
    if kind == 0 { t.warmCool = sender.doubleValue }
    else          { t.brightness = sender.doubleValue }
    tune[id] = t
    onPreview?(adjustedMap())
  }

  @objc private func beforeAfterToggled(_ sender: NSButton) {
    if sender.state == .on {
      onPreview?([:])   // identity everywhere → "before"
    } else {
      onPreview?(adjustedMap())
    }
  }

  @objc private func saveTapped(_ sender: NSButton) {
    onSave?(adjustedMap())
    close()
  }

  private func adjustedMap() -> [String: ColorCorrection] {
    var map: [String: ColorCorrection] = [:]
    guard let refID = displays.first?.id else { return map }
    map[refID] = .identity
    for d in displays.dropFirst() {
      let t = tune[d.id] ?? (warmCool: 0, brightness: 1)
      map[d.id] = ColorSyncAdjust.adjust(corrections[d.id] ?? .identity,
                                          warmCool: t.warmCool,
                                          brightness: t.brightness)
    }
    return map
  }

  private func screen(for id: String) -> NSScreen? { displays.first(where: { $0.id == id })?.screen }
  private func label(for id: String) -> String? { displays.first(where: { $0.id == id })?.label }

  /// Stop the listener and hide the patch card. Idempotent so it's safe whether
  /// teardown arrives via the close button (windowWillClose) or close().
  private func tearDown() {
    guard !didTearDown else { return }
    didTearDown = true
    transport.stop()
    card.hide()
  }

  override func close() {
    tearDown(); super.close()
  }

  // The title-bar close button bypasses close(); funnel both paths here so the
  // listener is always stopped and the owner drops its reference (re-entrancy).
  func windowWillClose(_ notification: Notification) {
    tearDown()
    onClose?()
  }
}
