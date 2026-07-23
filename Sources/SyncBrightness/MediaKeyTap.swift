import ApplicationServices
import Cocoa

private let kBrightnessUp = 2 // NX_KEYTYPE_BRIGHTNESS_UP
private let kBrightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN

// Apple keyboards on recent macOS deliver the brightness keys as ordinary
// key events with these virtual keycodes instead of the NSSystemDefined
// media-key event above. Both forms are handled: which one arrives depends on
// the keyboard and the macOS version, so neither can be assumed.
private let kVKBrightnessUp = 144
private let kVKBrightnessDown = 145

/// A decoded brightness-key press, independent of which event form carried it.
struct BrightnessKeyPress: Equatable {
  let increase: Bool
  let isKeyDown: Bool
}

/// Pure decoding of both event forms — no CGEvent needed, so it's unit-testable.
enum BrightnessKeyDecoder {
  /// NSSystemDefined media-key form: subtype 8, key code in the high word of `data1`.
  static func systemDefined(subtype: Int, data1: Int) -> BrightnessKeyPress? {
    guard subtype == 8 else { return nil }
    let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
    guard keyCode == kBrightnessUp || keyCode == kBrightnessDown else { return nil }
    let keyState = (data1 & 0xFF00) >> 8
    return BrightnessKeyPress(increase: keyCode == kBrightnessUp, isKeyDown: keyState == 0x0A)
  }

  /// Plain key-event form (keyDown/keyUp with a brightness virtual keycode).
  static func plainKey(keyCode: Int, isKeyDown: Bool) -> BrightnessKeyPress? {
    switch keyCode {
    case kVKBrightnessUp: return BrightnessKeyPress(increase: true, isKeyDown: isKeyDown)
    case kVKBrightnessDown: return BrightnessKeyPress(increase: false, isKeyDown: isKeyDown)
    default: return nil
    }
  }
}

/// Taps the system brightness keys. When the handler returns true the key is
/// swallowed (used in clamshell/external-only mode); otherwise it passes through
/// so macOS keeps driving the built-in display.
final class MediaKeyTap {
  /// (increase, isKeyDown) -> consume the event?
  var onBrightnessKey: ((Bool, Bool) -> Bool)?

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  static func accessibilityGranted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }

  var isRunning: Bool { tap != nil }

  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }
    guard AXIsProcessTrusted() else { return false }

    // systemDefined (media-key form) + key up/down (Apple-keyboard form). Both
    // are needed; see BrightnessKeyDecoder.
    let mask: CGEventMask = (1 << 14)
      | (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
      }
      if me.handle(event: event, type: type) { return nil }
      return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: mask,
                                      callback: callback,
                                      userInfo: refcon) else {
      return false
    }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func stop() {
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      runLoopSource = nil
    }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    tap = nil
  }

  private func handle(event: CGEvent, type: CGEventType) -> Bool {
    let press: BrightnessKeyPress?
    switch type {
    case .keyDown, .keyUp:
      let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
      press = BrightnessKeyDecoder.plainKey(keyCode: keyCode, isKeyDown: type == .keyDown)
    default:
      guard let nsEvent = NSEvent(cgEvent: event) else { return false }
      press = BrightnessKeyDecoder.systemDefined(subtype: Int(nsEvent.subtype.rawValue),
                                                 data1: nsEvent.data1)
    }
    guard let press else { return false }
    // Swallow the matching key-up too, so no half a key pair leaks through.
    return onBrightnessKey?(press.increase, press.isKeyDown) ?? false
  }
}
