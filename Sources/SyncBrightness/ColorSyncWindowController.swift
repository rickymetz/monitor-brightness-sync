import Cocoa

final class ColorSyncWindowController: NSWindowController, NSWindowDelegate {
  /// (display id, NSScreen, label). Reference first (built-in when present).
  var displays: [(id: String, screen: NSScreen, label: String)] = []
  var onSave: (([String: ColorCorrection]) -> Void)?
  /// Fired when the window closes so the owner can drop its reference (re-entrancy).
  var onClose: (() -> Void)?
  private var didTearDown = false

  private let transport = ColorSyncTransport()
  private let card = PatchCardWindow()
  private var session: ColorSyncSession?
  private var corrections: [String: ColorCorrection] = [:]
  private var tune: [String: (warmCool: Double, brightness: Double)] = [:]

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
    let refs = displays.map { DisplayRef(id: $0.id, label: $0.label) }
    guard let referenceID = displays.first?.id else {
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

    let session = ColorSyncSession(displays: refs, referenceID: referenceID, peer: transport)
    session.onPrepareReference = { [weak self] id in
      guard let self, let screen = self.screen(for: id) else { return }
      self.card.show(.midGray, on: screen)
      self.statusLabel.stringValue = "Aim your phone at the reference screen and hold steady to lock."
    }
    session.onShowCard = { [weak self] id in
      guard let self, let screen = self.screen(for: id), let label = self.label(for: id) else { return }
      self.card.show(.patchCard, on: screen)
      self.statusLabel.stringValue = "Photographing \(label)…"
    }
    session.onComplete = { [weak self] map in
      guard let self else { return }
      self.corrections = map
      self.card.hide()
      self.onSave?(map)                 // apply live immediately
      self.presentFineTune()
    }
    self.session = session
    transport.onReceive = { [weak self] msg in self?.session?.handle(msg) }
    transport.onClientConnected = { [weak self] in self?.session?.start() }
    showWindow(nil)
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

    // Apply current (identity) state immediately
    onSave?(adjustedMap())
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
    onSave?(adjustedMap())
  }

  @objc private func beforeAfterToggled(_ sender: NSButton) {
    if sender.state == .on {
      onSave?([:])   // identity everywhere → "before"
    } else {
      onSave?(adjustedMap())
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
