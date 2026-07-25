import CoreGraphics
import Foundation

/// One-shot probe used to verify the hardware paths without launching the UI.
/// Triggered by running the binary with SYNCBRIGHTNESS_DIAG=1.
enum Diagnostics {
  static func run(writeProbe: Bool = false) {
    var out = "Monitor Brightness Sync — diagnostics\n"

    if let builtin = BuiltinBrightness.builtinDisplayID() {
      let frac = BuiltinBrightness.fraction(of: builtin)
      out += "Built-in display id=\(builtin) brightness="
      out += frac.map { String(format: "%.0f%%", $0 * 100) } ?? "unavailable"
      out += "\n"
    } else {
      out += "Built-in display: not found\n"
    }

    let externals = DDC.externalDisplays()
    out += "External displays over DDC/CI: \(externals.count)\n"
    for (i, display) in externals.enumerated() {
      let result = DDC.read(service: display.service, command: kVCPBrightness)
      if let result {
        out += String(format: "  [%d] %@  id=%@  current=%d  max=%d (DDC read OK)\n",
                      i, display.name, display.id, Int(result.current), Int(result.max))
      } else {
        out += "  [\(i)] \(display.name)  id=\(display.id)  (DDC read failed)\n"
      }
      // Optional: probe whether writes are accepted (changes brightness to ~50%).
      if writeProbe {
        // Use the range the monitor just reported; maxBrightness is still the
        // 100 default here because nothing has called refreshMaxBrightness().
        let reported = result.map { Double($0.max) } ?? 0
        let range = reported > 0 ? reported : Double(display.maxBrightness)
        let probeValue = UInt16((range * 0.5).rounded())
        let wrote = DDC.write(service: display.service, command: kVCPBrightness, value: probeValue)
        out += "      DDC write probe (set ~50%): \(wrote ? "accepted (IOReturn OK)" : "FAILED")\n"
      }
    }

    out += "\nIORegistry display services:\n"
    for line in DDC.debugServiceDump() { out += "  \(line)\n" }

    var onlineCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &onlineCount)
    out += "CG online displays: \(onlineCount)\n"

    FileHandle.standardError.write(out.data(using: .utf8)!)
  }
}
