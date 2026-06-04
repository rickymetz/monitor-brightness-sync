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
      if let result = DDC.read(service: display.service, command: kVCPBrightness) {
        out += String(format: "  [%d] %@  id=%@  current=%d  max=%d (DDC read OK)\n",
                      i, display.name, display.id, Int(result.current), Int(result.max))
      } else {
        out += "  [\(i)] \(display.name)  id=\(display.id)  (DDC read failed)\n"
      }
      // Optional: probe whether writes are accepted (changes brightness to ~50%).
      if writeProbe {
        let probeValue = UInt16((Double(display.maxBrightness) * 0.5).rounded())
        let wrote = DDC.write(service: display.service, command: kVCPBrightness, value: probeValue)
        out += "      DDC write probe (set ~50%): \(wrote ? "accepted (IOReturn OK)" : "FAILED")\n"
      }
    }
    FileHandle.standardError.write(out.data(using: .utf8)!)
  }
}
