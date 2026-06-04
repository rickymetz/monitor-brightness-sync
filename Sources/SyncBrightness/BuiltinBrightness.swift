import CoreGraphics
import Foundation

/// Reads the built-in display's brightness (0...1) using the private
/// DisplayServices framework, loaded at runtime so we don't link against it.
enum BuiltinBrightness {
  private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

  private static let getBrightness: GetBrightnessFn? = {
    let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
  }()

  /// CGDirectDisplayID of the internal display, if one is present.
  static func builtinDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.first { CGDisplayIsBuiltin($0) != 0 }
  }

  /// Current built-in brightness as a 0...1 fraction.
  static func fraction(of displayID: CGDirectDisplayID) -> Double? {
    guard let getBrightness else { return nil }
    var value: Float = 0
    guard getBrightness(displayID, &value) == 0 else { return nil }
    return Double(max(0, min(1, value)))
  }
}
