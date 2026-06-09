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
  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String) -> [String: ColorCorrection] {
    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [:] }
    let rw = ref.samples.white

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
      result[m.displayID] = ColorCorrection(redGain: r, greenGain: g, blueGain: b, gamma: 1)
    }
    return result
  }
}
