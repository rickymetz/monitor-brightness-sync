import ApplicationServices
import Cocoa

private let kBrightnessUp = 2 // NX_KEYTYPE_BRIGHTNESS_UP
private let kBrightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN

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

    let mask: CGEventMask = 1 << 14 // NSEvent.EventType.systemDefined
    let refcon = Unmanaged.passUnretained(self).toOpaque()

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
      }
      if me.handle(event: event) { return nil }
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

  private func handle(event: CGEvent) -> Bool {
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
    let data1 = nsEvent.data1
    let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
    guard keyCode == kBrightnessUp || keyCode == kBrightnessDown else { return false }
    let keyState = (data1 & 0xFF00) >> 8
    let isKeyDown = keyState == 0x0A
    return onBrightnessKey?(keyCode == kBrightnessUp, isKeyDown) ?? false
  }
}
