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

  private let imageView = NSImageView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

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
    statusLabel.stringValue = "Done — colors matched. Fine-tune coming next; close to keep."
    imageView.image = nil
    // Fine-tune sliders are added in Task A10.
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
