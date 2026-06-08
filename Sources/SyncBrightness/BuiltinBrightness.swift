import CoreGraphics
import Foundation

/// Reads the built-in display's brightness (0...1) using the private
/// DisplayServices framework, loaded at runtime so we don't link against it.
enum BuiltinBrightness {
  private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

  private static let handle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

  private static let getBrightness: GetBrightnessFn? = {
    guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
  }()

  private static let setBrightness: SetBrightnessFn? = {
    guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: SetBrightnessFn.self)
  }()

  /// CGDirectDisplayID of the internal display, if one is present.
  static func builtinDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.first { CGDisplayIsBuiltin($0) != 0 }
  }

  /// Current brightness of any display as a 0...1 fraction, via DisplayServices.
  /// Works for the built-in and — on many setups — external displays too, which
  /// is a useful second read path when raw DDC reads are flaky.
  static func fraction(of displayID: CGDirectDisplayID) -> Double? {
    guard let getBrightness else { return nil }
    var value: Float = 0
    guard getBrightness(displayID, &value) == 0 else { return nil }
    return Double(max(0, min(1, value)))
  }

  /// Set a display's brightness from a 0...1 fraction via DisplayServices. Used
  /// to drive the built-in from custom hotkeys (the sync loop then mirrors it).
  @discardableResult
  static func setFraction(_ fraction: Double, of displayID: CGDirectDisplayID) -> Bool {
    guard let setBrightness else { return false }
    return setBrightness(displayID, Float(max(0, min(1, fraction)))) == 0
  }
}
