import Foundation

struct DisplayMeasurement {
  let displayID: String
  let samples: PatchSamples
}

/// Locked-camera color matcher. All photos in a session share ONE fixed camera
/// transform G (the iOS app locks WB + exposure once), so the per-channel ratio
/// of two displays' measured whites equals the ratio of their emitted whites — G
/// cancels. We correct chroma only (attenuate-only, peak channel normalized to 1)
/// so overall brightness is left to the brightness-sync feature.
enum ColorMatcher {
  /// Displayed input levels of the gray ramp, mapped to gray25 / gray50 / white.
  static let rampLevels: [Double] = [0.25, 0.5, 0.8]

  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String) -> [String: ColorCorrection] {
    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [:] }
    let rw = ref.samples.white
    let refGamma = effectiveGamma(ref.samples)

    // dead channel (no emission): don't attenuate — can't compensate for missing light
    func gain(_ refC: Double, _ tgtC: Double) -> Double { tgtC > 1e-6 ? refC / tgtC : 1 }

    var result: [String: ColorCorrection] = [:]
    for m in measurements {
      if m.displayID == referenceID { result[m.displayID] = .identity; continue }
      let tw = m.samples.white
      var r = gain(rw.r, tw.r)
      var g = gain(rw.g, tw.g)
      var b = gain(rw.b, tw.b)
      let peak = max(r, max(g, b))
      if peak > 1e-6 { r /= peak; g /= peak; b /= peak }
      // Corrective gamma so the target's tone curve matches the reference's. The
      // camera's own response is a common factor and cancels in the ratio. Clamped.
      let tgtGamma = effectiveGamma(m.samples)
      let gammaCorr = tgtGamma > 1e-3 ? min(2.0, max(0.5, refGamma / tgtGamma)) : 1
      result[m.displayID] = ColorCorrection(redGain: r, greenGain: g, blueGain: b, gamma: gammaCorr)
    }
    return result
  }

  /// Effective luminance gamma fit from the gray ramp (gray25/gray50 relative to
  /// the brightest field). Returns 1 when undeterminable. Camera response is
  /// included but cancels when two displays' gammas are ratioed.
  static func effectiveGamma(_ s: PatchSamples) -> Double {
    func lum(_ c: RGB) -> Double { (c.r + c.g + c.b) / 3 }
    let bright = lum(s.white)                 // displayed at rampLevels.last (0.8)
    guard bright > 1e-6, let top = rampLevels.last else { return 1 }
    let points = [(rampLevels[0], lum(s.gray25)), (rampLevels[1], lum(s.gray50))]
    var sum = 0.0, n = 0.0
    for (level, value) in points {
      let rel = value / bright
      let x = level / top
      if rel > 1e-3, rel < 0.999, x > 1e-3, x < 0.999 {
        sum += log(rel) / log(x); n += 1
      }
    }
    return n > 0 ? sum / n : 1
  }
}
