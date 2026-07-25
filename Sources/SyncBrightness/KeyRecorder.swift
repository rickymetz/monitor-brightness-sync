import Carbon
import Cocoa

/// A small button that records a keyboard shortcut: click it, press a combo, and
/// it captures the keycode + modifiers. Escape cancels; Delete clears. Requires
/// at least one of ⌃⌥⌘ so it can't bind a bare key that would be hijacked
/// system-wide.
final class KeyRecorder: NSButton {
  /// Called with the new combo, or nil when cleared.
  var onCapture: ((KeyCombo?) -> Void)?

  var combo: KeyCombo? { didSet { updateTitle() } }
  private var recording = false { didSet { updateTitle() } }
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?

  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(beginRecording)
    updateTitle()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func beginRecording() {
    guard !recording else { return }
    recording = true
    window?.makeFirstResponder(self)
    // Capture keys locally while recording so they don't also act elsewhere.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      guard let self, self.recording else { return event }
      if event.type == .keyDown { return self.handle(event) ? nil : event }
      return event // ignore flagsChanged; wait for a real key
    }
    // If the user clicks away instead of pressing a combo, stop listening —
    // otherwise the monitor stays installed and eats the next ⌘-anything as a
    // binding, with the button stuck on "Type shortcut…".
    if let window {
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in self?.endRecording() }
    }
  }

  private func endRecording() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
  }

  /// Returns true if the event was consumed (captured, cleared, or cancelled).
  private func handle(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53: // Escape — cancel, keep the existing combo
      endRecording(); return true
    case 51, 117: // Delete / Forward-delete — clear
      combo = nil; endRecording(); onCapture?(nil); return true
    default:
      break
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
      return false // need a non-shift modifier; ignore and keep listening
    }
    let new = KeyCombo(keyCode: UInt32(event.keyCode),
                       carbonModifiers: KeyCombo.carbonModifiers(from: flags),
                       display: Self.displayString(event: event, flags: flags))
    combo = new
    endRecording()
    onCapture?(new)
    return true
  }

  private func updateTitle() {
    title = recording ? "Type shortcut…" : (combo?.display ?? "Record shortcut")
  }

  // MARK: - Display string

  private static func displayString(event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
    var s = ""
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option) { s += "⌥" }
    if flags.contains(.shift) { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    return s + keyLabel(for: event)
  }

  private static let specialKeys: [UInt16: String] = [
    126: "↑", 125: "↓", 123: "←", 124: "→",
    49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  ]

  private static func keyLabel(for event: NSEvent) -> String {
    if let s = specialKeys[event.keyCode] { return s }
    if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
      return chars.uppercased()
    }
    return "Key \(event.keyCode)"
  }
}
