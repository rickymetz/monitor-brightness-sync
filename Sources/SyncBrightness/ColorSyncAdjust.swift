import Foundation

/// Pure fine-tune: bias an automatic correction by a warm/cool dial (-1...1) and a
/// brightness scale (0.5...1), keeping gains in 0...1.
enum ColorSyncAdjust {
  static func adjust(_ base: ColorCorrection, warmCool: Double, brightness: Double) -> ColorCorrection {
    let warm = 1 + 0.15 * warmCool     // >1 favors red, <1 favors blue
    var r = base.redGain * warm * brightness
    let g = base.greenGain * brightness
    var b = base.blueGain / warm * brightness
    let peak = max(r, max(g, b))
    if peak > 1 { r /= peak; b /= peak }   // only renormalize if we exceeded 1
    return ColorCorrection(redGain: min(1, r), greenGain: min(1, g), blueGain: min(1, b), gamma: base.gamma)
  }
}
