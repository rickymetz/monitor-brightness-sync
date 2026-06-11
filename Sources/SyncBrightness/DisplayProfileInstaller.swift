import CoreGraphics
import ColorSync
import Foundation

/// Installs/restores a custom ICC profile on a display via ColorSync, and reads a
/// display's calibrated RGB→XYZ (the reference anchor for the 3×3 correction).
///
/// ColorSync's per-device custom profile overrides the factory profile for that
/// display system-wide; the WindowServer then color-manages content into it, which
/// is how a 3×3 primaries correction reaches arbitrary on-screen content (the
/// gamma-table path can only do per-channel/diagonal). Restored to factory on reset
/// and on quit.
enum DisplayProfileInstaller {
  /// The display's calibrated RGB→XYZ matrix (columns = R,G,B primary XYZ), read from
  /// its current ColorSync profile. Used as `P_ref` to anchor the target's profile.
  static func referenceRGBtoXYZ(_ cg: CGDirectDisplayID) -> Matrix3? {
    guard let space = CGDisplayCopyColorSpace(cg) as CGColorSpace?,
          let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else { return nil }
    func primary(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> RGB? {
      var comps: [CGFloat] = [r, g, b, 1]
      guard let c = CGColor(colorSpace: space, components: &comps),
            let conv = c.converted(to: xyz, intent: .relativeColorimetric, options: nil),
            let cc = conv.components, cc.count >= 3 else { return nil }
      return RGB(r: Double(cc[0]), g: Double(cc[1]), b: Double(cc[2]))
    }
    guard let r = primary(1, 0, 0), let g = primary(0, 1, 0), let b = primary(0, 0, 1) else { return nil }
    return Matrix3(columns: r, g, b)
  }

  /// Directory where we keep generated ICCs (ColorSync references them by URL, so the
  /// file must persist while installed).
  private static var profileDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("MonitorBrightnessSync/profiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private static func profileURL(for displayID: String) -> URL {
    let safe = displayID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
    return profileDir.appendingPathComponent("\(safe).icc")
  }

  private static func uuid(_ cg: CGDirectDisplayID) -> CFUUID? {
    CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue()
  }

  // ColorSync exports these as Unmanaged<CFString> constants; unwrap once.
  private static var displayClass: CFString? { kColorSyncDisplayDeviceClass?.takeUnretainedValue() }
  private static var defaultProfileID: CFString? { kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() }

  /// Build an ICC from `rgbToXYZ` (+ gamma) and install it as `cg`'s custom profile.
  /// `displayID` names the on-disk ICC so re-installs overwrite cleanly. Returns true
  /// only if ColorSync accepted the override.
  @discardableResult
  static func install(rgbToXYZ m: Matrix3, gamma: (r: Double, g: Double, b: Double),
                      onDisplay cg: CGDirectDisplayID, displayID: String) -> Bool {
    guard let icc = ICCProfileBuilder.iccData(rgbToXYZ: m, gamma: gamma),
          let dev = uuid(cg), let cls = displayClass, let pid = defaultProfileID else { return false }
    let url = profileURL(for: displayID)
    do { try icc.write(to: url, options: .atomic) } catch { return false }
    let info: [CFString: Any] = [pid: url as CFURL]
    return ColorSyncDeviceSetCustomProfiles(cls, dev, info as CFDictionary)
  }

  /// Revert `cg` to its factory profile (kCFNull clears the custom override) and
  /// delete our generated ICC.
  @discardableResult
  static func restore(onDisplay cg: CGDirectDisplayID, displayID: String) -> Bool {
    defer { try? FileManager.default.removeItem(at: profileURL(for: displayID)) }
    guard let dev = uuid(cg), let cls = displayClass, let pid = defaultProfileID else { return false }
    let info: [CFString: Any] = [pid: kCFNull as Any]
    return ColorSyncDeviceSetCustomProfiles(cls, dev, info as CFDictionary)
  }
}
