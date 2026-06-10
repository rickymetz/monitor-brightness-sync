import Foundation

/// DDC/CI (VESA MCCS) color control codes and the pure mapping from a diagonal
/// `ColorCorrection` to hardware gain values.
///
/// Why hardware over the gamma table: `CGSetDisplayTransferByFormula` is
/// attenuate-only and quantizes in the GPU LUT (banding at low brightness). The
/// monitor's own per-channel video-gain controls drive the panel directly at full
/// range. We use a HYBRID: when a monitor exposes these (optional) codes, the
/// white-point gains go to hardware; the per-channel gamma and any residual stay
/// on the gamma table (there is no standard MCCS "gamma" code).
///
/// Codes are confirmed against the VESA MCCS standard / ddcutil's feature table:
///   0x16/0x18/0x1A = Video gain (Red/Green/Blue)  — white point
///   0x6C/0x6E/0x70 = Video black level (R/G/B)     — offset/lift  (NOT 0x1B/1D/1F)
enum DDCColor {
  static let redGain: UInt8 = 0x16
  static let greenGain: UInt8 = 0x18
  static let blueGain: UInt8 = 0x1A
  static let redBlackLevel: UInt8 = 0x6C
  static let greenBlackLevel: UInt8 = 0x6E
  static let blueBlackLevel: UInt8 = 0x70

  static let gainCodes: [UInt8] = [redGain, greenGain, blueGain]
  static let blackLevelCodes: [UInt8] = [redBlackLevel, greenBlackLevel, blueBlackLevel]

  /// Which color controls a given monitor actually answered when probed.
  struct Capabilities: Equatable {
    var gain: Bool          // all three gain codes readable
    var blackLevel: Bool    // all three black-level codes readable
    static let none = Capabilities(gain: false, blackLevel: false)
    var any: Bool { gain || blackLevel }
  }

  /// Per-channel hardware gain values to write, derived from an attenuate-only
  /// diagonal correction. `baseline` is each channel's current/neutral gain value
  /// (read from the monitor) and `maxValue` its reported max. The peak channel
  /// (gain ≈ 1) stays at baseline; the others scale down proportionally — exactly
  /// the white-point shift our correction encodes. Result is clamped to 0…max.
  ///
  /// The correction's `gamma` is intentionally ignored here: there is no MCCS
  /// gamma code, so gamma remains the gamma table's job in the hybrid.
  static func gainValues(correction c: ColorCorrection,
                         baseline: (r: UInt16, g: UInt16, b: UInt16),
                         maxValue: UInt16) -> (r: UInt16, g: UInt16, b: UInt16) {
    func v(_ gain: Double, _ base: UInt16) -> UInt16 {
      let scaled = (Double(base) * max(0, min(1, gain))).rounded()
      return UInt16(max(0, min(Double(maxValue), scaled)))
    }
    return (v(c.redGain, baseline.r), v(c.greenGain, baseline.g), v(c.blueGain, baseline.b))
  }

  /// True when the correction has a non-trivial white-point shift worth pushing
  /// to hardware (some channel attenuated below ~unity).
  static func hasGainShift(_ c: ColorCorrection, epsilon: Double = 1e-3) -> Bool {
    c.redGain < 1 - epsilon || c.greenGain < 1 - epsilon || c.blueGain < 1 - epsilon
  }
}
