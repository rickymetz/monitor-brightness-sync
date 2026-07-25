import Carbon
import Cocoa

/// A user-chosen key combination, stored as a Carbon keycode + modifier mask
/// plus a pre-rendered display string (computed at capture time so we don't
/// need a full keycode→glyph decoder).
struct KeyCombo: Codable, Equatable {
  var keyCode: UInt32
  var carbonModifiers: UInt32
  var display: String

  /// ⌃⌥↑ / ⌃⌥↓ — sensible, usually-free defaults (Up=126, Down=125 arrows).
  static let defaultUp = KeyCombo(keyCode: 126, carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥↑")
  static let defaultDown = KeyCombo(keyCode: 125, carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥↓")

  /// Convert AppKit modifier flags to the Carbon mask RegisterEventHotKey wants.
  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var c: UInt32 = 0
    if flags.contains(.command) { c |= UInt32(cmdKey) }
    if flags.contains(.option) { c |= UInt32(optionKey) }
    if flags.contains(.control) { c |= UInt32(controlKey) }
    if flags.contains(.shift) { c |= UInt32(shiftKey) }
    return c
  }
}

/// A single global hotkey registered via Carbon. Carbon hotkeys are system-wide
/// and need no Accessibility grant (unlike an event tap), so they work whether
/// or not the lid-closed key tap is enabled. Fires `onPress` on key-down.
final class HotKey {
  var onPress: (() -> Void)?

  private var ref: EventHotKeyRef?
  private let id: UInt32

  /// The registry only needs to find the instance for a firing hotkey id — it
  /// must not keep it alive, or `deinit` (and with it `unregister`) is never
  /// reached for a registered hotkey.
  private final class WeakRef {
    weak var hotKey: HotKey?
    init(_ hotKey: HotKey) { self.hotKey = hotKey }
  }

  private static let signature: OSType = 0x4D425348 // 'MBSH'
  private static var instances: [UInt32: WeakRef] = [:]
  private static var nextID: UInt32 = 1
  private static var handlerInstalled = false

  init() {
    id = HotKey.nextID
    HotKey.nextID += 1
    HotKey.installHandlerIfNeeded()
  }

  deinit { unregister() }

  @discardableResult
  func register(_ combo: KeyCombo) -> Bool {
    unregister()
    let hkID = EventHotKeyID(signature: HotKey.signature, id: id)
    var newRef: EventHotKeyRef?
    let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                     GetEventDispatcherTarget(), 0, &newRef)
    guard status == noErr, let newRef else { return false }
    ref = newRef
    HotKey.instances[id] = WeakRef(self)
    return true
  }

  func unregister() {
    if let ref { UnregisterEventHotKey(ref); self.ref = nil }
    HotKey.instances[id] = nil
  }

  private static func installHandlerIfNeeded() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
      guard let event else { return noErr }
      var hkID = EventHotKeyID()
      let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
      if err == noErr, let hk = HotKey.instances[hkID.id]?.hotKey { hk.onPress?() }
      return noErr
    }, 1, &spec, nil, nil)
  }
}
