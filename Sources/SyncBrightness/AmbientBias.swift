import Foundation

/// Maps an ambient color-temperature reading to a warm/cool fine-tune suggestion.
///
/// The only Apple-sanctioned ambient color signal on iOS is ARKit's
/// `ARLightEstimate.ambientColorTemperature` (degrees Kelvin; 6500 = neutral).
/// It is camera-derived (not the True Tone sensor — that subsystem has no public
/// or non-jailbreak API), so we treat it as a *suggested starting bias* the user
/// can override, not a measurement. This mapping is pure and shared so both the
/// phone (which reads ARKit) and the Mac (which applies it to the tune sliders)
/// agree, and so it's unit-testable without a device.
enum AmbientBias {
  static let neutralKelvin: Double = 6500
  /// Kelvin span that maps to full-scale bias (±1) at the extremes.
  static let span: Double = 3500

  /// Warm/cool bias in -1...1 for ColorSyncAdjust. A warmer room (lower Kelvin)
  /// suggests a warmer display (positive → favors red); a cooler room suggests a
  /// cooler display (negative → favors blue). 6500K → 0.
  static func warmCool(forKelvin k: Double) -> Double {
    guard k > 0 else { return 0 }
    return max(-1, min(1, (neutralKelvin - k) / span))
  }
}
