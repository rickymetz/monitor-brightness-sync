import Cocoa

final class ColorSyncWindowController: NSWindowController, NSWindowDelegate {
  /// (display id, NSScreen, label). Reference first (built-in when present).
  var displays: [(id: String, screen: NSScreen, label: String)] = []
  /// Apply a correction map LIVE without persisting (preview/fine-tune).
  var onPreview: (([String: ColorCorrection]) -> Void)?
  /// Persist (and apply) a correction map. Only called from the Save button.
  var onSave: (([String: ColorCorrection]) -> Void)?
  /// Install the 3×3 (ICC) color profiles from the measured samples, without
  /// persisting (preview, so the side-by-side verify reflects the real match).
  var onApplyProfiles: (([String: PatchSamples], String) -> Void)?
  /// Persist the measurement and install its 3×3 (ICC) profiles. From the Save button.
  var onSaveProfiles: (([String: PatchSamples], String) -> Void)?
  /// Revert the corrected displays to factory ICC (the "Before" A/B state).
  var onClearProfiles: (() -> Void)?
  /// Fired when the window closes so the owner can drop its reference (re-entrancy).
  var onClose: (() -> Void)?
  /// Show / hide the uniform test field (with A/B labels) on every display, for
  /// the side-by-side verify.
  var onShowTestField: (() -> Void)?
  var onHideTestField: (() -> Void)?
  private var didTearDown = false

  private let transport = ColorSyncTransport()
  private let card = PatchCardWindow()
  private var corrections: [String: ColorCorrection] = [:]
  private var tune: [String: (warmCool: Double, brightness: Double)] = [:]

  // Capture orchestration (Mac drives the fields; phone measures on request).
  // Three neutral gray levels (gamma/white-point) followed by the three primaries
  // (gamut), so ColorMatcher gets real R/G/B instead of white placeholders.
  private let captureFields: [PatchCardWindow.Content] = [
    .solid(0.25), .solid(0.5), .solid(0.8),
    .color(RGB(r: 1, g: 0, b: 0)), .color(RGB(r: 0, g: 1, b: 0)), .color(RGB(r: 0, g: 0, b: 1)),
  ]
  private let lockLevel = 0.8                             // lock exposure on the brightest level
  private let settleDelay = 0.6                           // wait after showing a field before measuring
  private let darkDelay = 0.25                            // brief black flash between fields
  private var displayIndex = -1
  private var levelIndex = 0
  private var rampReadings: [RGB] = []
  private var rampSources: [String] = []
  private var collectedSamples: [String: PatchSamples] = [:]
  private var collectedSources: [String: [String]] = [:]
  private var matchReports: [ColorMatcher.MatchReport] = []

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

  /// Replace the display list after a hotplug (called from AppDelegate's monitor
  /// callback). No-op once a measurement is underway or done this session, so a
  /// display change mid-ramp (or after results are shown) can't reshuffle the
  /// sequence or wipe the fine-tune UI — re-open the window to pick it up then.
  func refreshDisplays(_ list: [(id: String, screen: NSScreen, label: String)]) {
    guard displayIndex < 0, collectedSamples.isEmpty else { return }
    let before = Set(displays.map { $0.id })
    displays = list
    if Set(list.map { $0.id }) != before, let ref = displays.first {
      // Re-show the lock field on the (possibly new) reference and refresh the hint.
      if let screen = screen(for: ref.id) { card.show(.solid(lockLevel), on: screen) }
      statusLabel.stringValue = "Displays updated (\(list.count) found). Press your phone to \(ref.label) and tap Lock & Start."
    }
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
    case .measured(let level, let r, let g, let b, let source) where level == levelIndex && displayIndex >= 0:
      rampReadings.append(RGB(r: r, g: g, b: b))
      rampSources.append(source)
      levelIndex += 1
      if levelIndex < captureFields.count { showLevelThenMeasure() } else { finishDisplay() }
    case .beginVerify:
      onShowTestField?()
    case .sideBySide(let aR, let aG, let aB, let bR, let bG, let bB):
      onHideTestField?()
      reportSideBySide(a: RGB(r: aR, g: aG, b: aB), b: RGB(r: bR, g: bG, b: bB))
    case .ambient(let kelvin):
      applyAmbientBias(kelvin: kelvin)
    case .debug(let message):
      ColorSyncDebugLog.log("PHONE \(message)")
    default:
      break
    }
  }

  /// Apply an ARKit ambient color-temperature reading as a *suggested* warm/cool
  /// starting bias on every non-reference display, then refresh the fine-tune.
  /// The user can still drag the sliders afterward.
  private func applyAmbientBias(kelvin: Double) {
    guard !corrections.isEmpty else { return }   // only meaningful once we have a match to bias
    let bias = AmbientBias.warmCool(forKelvin: kelvin)
    for d in displays.dropFirst() {
      var t = tune[d.id] ?? (warmCool: 0, brightness: 1)
      t.warmCool = bias
      tune[d.id] = t
    }
    presentFineTune()   // rebuilds sliders from `tune`, so they reflect the suggestion
    statusLabel.stringValue = String(format: "Room light ≈ %.0fK → suggested warm/cool %+.2f. Adjust or Save.",
                                     kelvin, bias)
  }

  /// Verdict on a side-by-side debug capture. Judges CHROMA (luminance-normalized)
  /// — what color sync actually corrects — and reports the brightness difference
  /// separately (that's the brightness-sync feature's job, not color sync's).
  private func reportSideBySide(a: RGB, b: RGB) {
    let m = SideBySideMetric.compare(a, b)
    statusLabel.stringValue = String(
      format: "Side-by-side check:\nA (%.3f, %.3f, %.3f)  B (%.3f, %.3f, %.3f)\nMatch ΔE %.1f — %@\n(color ΔE %.1f, brightness Δ %.3f)",
      a.r, a.g, a.b, b.r, b.g, b.b, m.deltaE, m.verdict, m.chromaOnly, m.brightness)
    ColorSyncDebugLog.log(String(format: "VERIFY  A(%.3f,%.3f,%.3f) B(%.3f,%.3f,%.3f)  matchΔE %.2f (%@)  colorΔE %.2f  brightnessΔ %.3f",
      a.r, a.g, a.b, b.r, b.g, b.b, m.deltaE, m.verdict, m.chromaOnly, m.brightness))
    // What's actually applied right now (base correction folded with the sliders).
    for (id, c) in adjustedMap() {
      let label = displays.first(where: { $0.id == id })?.label ?? id
      ColorSyncDebugLog.log(String(format: "VERIFY applied  %@ [%@]  gains R %.3f G %.3f B %.3f γ %.3f",
        label, id, c.redGain, c.greenGain, c.blueGain, c.gamma))
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
    rampSources = []
    showLevelThenMeasure()
  }

  private func showLevelThenMeasure() {
    guard let screen = currentDisplayID.flatMap({ screen(for: $0) }) else { return }
    let field = captureFields[levelIndex]
    // Brief black flash, then the field, then measure once it has settled.
    card.show(.dark, on: screen)
    DispatchQueue.main.asyncAfter(deadline: .now() + darkDelay) { [weak self] in
      guard let self else { return }
      self.card.show(field, on: screen)
      DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDelay) { [weak self] in
        guard let self, self.displayIndex >= 0 else { return }
        self.transport.send(.measure(level: self.levelIndex))
      }
    }
  }

  private func finishDisplay() {
    guard let id = currentDisplayID, rampReadings.count == captureFields.count else { return }
    // captureFields = gray25, gray50, white(0.8), red, green, blue.
    collectedSamples[id] = PatchSamples(white: rampReadings[2], gray50: rampReadings[1],
                                        gray25: rampReadings[0],
                                        red: rampReadings[3], green: rampReadings[4], blue: rampReadings[5])
    collectedSources[id] = rampSources
    if displayIndex + 1 < displays.count { promptDisplay(displayIndex + 1) } else { finishAll() }
  }

  private func finishAll() {
    transport.send(.done)
    card.hide()
    displayIndex = -1
    let measurements = collectedSamples.map { DisplayMeasurement(displayID: $0.key, samples: $0.value) }
    corrections = ColorMatcher.corrections(measurements: measurements, referenceID: referenceID)
    matchReports = ColorMatcher.report(measurements: measurements, referenceID: referenceID,
                                       corrections: corrections)
    // Install the full 3×3 (ICC) correction from the measured samples — this is the
    // real color match. The diagonal `corrections` above are kept only for the
    // on-screen readout/quality numbers, not applied (ICC supersedes them).
    onApplyProfiles?(collectedSamples, referenceID)

    // Diagnostics to file (readable without screenshots).
    ColorSyncDebugLog.session("MEASUREMENT  reference=\(referenceID)")
    for d in displays {
      if let src = collectedSources[d.id] {
        ColorSyncDebugLog.log("\(d.label) [\(d.id)] capture source per field: \(src.joined(separator: ", "))")
      }
      if let s = collectedSamples[d.id] {
        ColorSyncDebugLog.log(String(format: "%@ [%@] measured  white(%.3f,%.3f,%.3f) gray50(%.3f,%.3f,%.3f) gray25(%.3f,%.3f,%.3f) R(%.3f,%.3f,%.3f) G(%.3f,%.3f,%.3f) B(%.3f,%.3f,%.3f)",
          d.label, d.id, s.white.r, s.white.g, s.white.b, s.gray50.r, s.gray50.g, s.gray50.b,
          s.gray25.r, s.gray25.g, s.gray25.b, s.red.r, s.red.g, s.red.b,
          s.green.r, s.green.g, s.green.b, s.blue.r, s.blue.g, s.blue.b))
      }
      if let c = corrections[d.id] {
        ColorSyncDebugLog.log(String(format: "%@ [%@] gains  R %.3f G %.3f B %.3f  γ %.3f%@",
          d.label, d.id, c.redGain, c.greenGain, c.blueGain, c.gamma,
          d.id == referenceID ? "  (reference)" : ""))
      }
      if let rep = matchReports.first(where: { $0.displayID == d.id }) {
        ColorSyncDebugLog.log(String(format: "%@ [%@] match  diagonalΔE %.2f  matrixΔE %.2f  worst:%@",
          d.label, d.id, rep.diagonalDeltaE, rep.matrixDeltaE, rep.worstPatch))
      }
    }
    presentFineTune()
    // Diagnostic readout: measured white RGB + gamma/gains, plus the ΔE2000 match
    // quality (what the diagonal achieves vs. the headroom a 3×3/ICC path would buy).
    var lines = ["Measured (white field) → correction:"]
    for d in displays {
      if let w = collectedSamples[d.id]?.white {
        lines.append(String(format: "%@:  R %.3f  G %.3f  B %.3f", d.label, w.r, w.g, w.b))
      }
      if let c = corrections[d.id] {
        lines.append(String(format: "   → gains R %.2f G %.2f B %.2f  γ %.2f",
                            c.redGain, c.greenGain, c.blueGain, c.gamma))
      }
      if let rep = matchReports.first(where: { $0.displayID == d.id }) {
        lines.append(String(format: "   match ΔE %.1f (3×3 would reach %.1f; worst: %@)",
                            rep.diagonalDeltaE, rep.matrixDeltaE, rep.worstPatch))
      }
    }
    statusLabel.stringValue = lines.joined(separator: "\n")
    // Set up the side-by-side check automatically: show the A/B test field on every
    // display. Tap "Verify side-by-side" on the phone; the result hides it again.
    onShowTestField?()
  }

  private func presentFineTune() {
    statusLabel.stringValue = "Done — 3×3 color match applied. Check it against the test field, then Save."
    imageView.image = nil

    // Remove any previous tune UI (e.g. if presentFineTune is called again)
    tuneStack?.removeFromSuperview()

    guard !displays.dropFirst().isEmpty else { return }

    var rows: [NSView] = []

    // A/B the full ICC correction against the factory profile (no per-channel sliders
    // in v1 — the 3×3 IS the match; a warm/cool nudge can layer on later).
    let beforeAfter = NSButton(checkboxWithTitle: "Before (factory profile)", target: self,
                               action: #selector(beforeAfterToggled(_:)))
    rows.append(beforeAfter)

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
      onClearProfiles?()                              // factory profiles → "before"
    } else {
      onApplyProfiles?(collectedSamples, referenceID) // re-install the 3×3 match → "after"
    }
  }

  @objc private func saveTapped(_ sender: NSButton) {
    // v1 saves the 3×3 (ICC) measurement; the diagonal gamma-table path is superseded.
    onSaveProfiles?(collectedSamples, referenceID)
    close()
  }

  private func adjustedMap() -> [String: ColorCorrection] {
    var map: [String: ColorCorrection] = [:]
    guard let refID = displays.first?.id else { return map }
    // The reference is NOT necessarily identity: when matching brightness down to a
    // dimmer display, the reference (e.g. the brighter built-in) carries its own
    // dimming correction. Apply it as computed (no warm/cool/brightness slider).
    map[refID] = corrections[refID] ?? .identity
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
