import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
  if !condition { failures += 1 }
}

print("== VCP code constants (VESA MCCS) ==")
check(DDCColor.redGain == 0x16 && DDCColor.greenGain == 0x18 && DDCColor.blueGain == 0x1A, "gain codes 0x16/0x18/0x1A")
check(DDCColor.redBlackLevel == 0x6C && DDCColor.greenBlackLevel == 0x6E && DDCColor.blueBlackLevel == 0x70,
      "black-level codes 0x6C/0x6E/0x70 (not 0x1B/0x1D/0x1F)")

print("== identity correction leaves baseline untouched ==")
let base: (r: UInt16, g: UInt16, b: UInt16) = (100, 100, 100)
let idv = DDCColor.gainValues(correction: .identity, baseline: base, maxValue: 100)
check(idv == (100, 100, 100), "identity → baseline unchanged")
check(!DDCColor.hasGainShift(.identity), "identity has no gain shift")

print("== warm target attenuates red, others unchanged ==")
let warm = ColorCorrection(redGain: 1.0 / 1.2, greenGain: 1.0, blueGain: 1.0, gamma: 1.0)
let wv = DDCColor.gainValues(correction: warm, baseline: base, maxValue: 100)
check(wv.r == UInt16((100.0 / 1.2).rounded()) && wv.r == 83, "red scaled to 83")
check(wv.g == 100 && wv.b == 100, "green/blue stay at baseline")
check(DDCColor.hasGainShift(warm), "warm correction is a real gain shift")

print("== respects per-channel baseline and clamps to max ==")
let mixedBase: (r: UInt16, g: UInt16, b: UInt16) = (80, 50, 100)
let c = ColorCorrection(redGain: 0.5, greenGain: 1.0, blueGain: 0.25, gamma: 1.0)
let mv = DDCColor.gainValues(correction: c, baseline: mixedBase, maxValue: 100)
check(mv.r == 40, "red 0.5 * baseline 80 = 40")
check(mv.g == 50, "green 1.0 * baseline 50 = 50")
check(mv.b == 25, "blue 0.25 * baseline 100 = 25")
// A gain above 1 (shouldn't happen, but guard) clamps to max.
let over = ColorCorrection(redGain: 5, greenGain: 1, blueGain: 1, gamma: 1)
check(DDCColor.gainValues(correction: over, baseline: (90, 90, 90), maxValue: 100).r == 90, "gain clamped to ≤1 → baseline")

print("== gamma is ignored by the hardware mapping (stays on the gamma table) ==")
let withGamma = ColorCorrection(redGain: 1, greenGain: 1, blueGain: 1, gamma: 1.8)
check(DDCColor.gainValues(correction: withGamma, baseline: base, maxValue: 100) == (100, 100, 100),
      "gamma does not affect gain values")

print("== capabilities ==")
check(!DDCColor.Capabilities.none.any, "no caps → any == false")
check(DDCColor.Capabilities(gain: true, blackLevel: false).any, "gain only → any == true")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
