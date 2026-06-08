import Foundation

struct DisplayMeasurement {
  let displayID: String
  let samples: PatchSamples
}

/// Turns photographed patch samples into a per-display ColorCorrection relative
/// to a reference display. Uses only WITHIN-photo channel ratios so the unknown
/// per-photo camera gain cancels. White-point (warm/cool) is the part the camera
/// neutralizes, so it is applied damped.
enum ColorMatcher {
  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String,
                          whitePointDamping: Double = 0.3) -> [String: ColorCorrection] {

    // Intrinsic channel "balance" of a display from mid-gray relative to white.
    // (camGain * emittedGray) / (camGain * emittedWhite) = emittedGray/emittedWhite — gain cancels.
    func balance(_ s: PatchSamples) -> (r: Double, g: Double, b: Double) {
      func ratio(_ num: Double, _ den: Double) -> Double { den > 1e-6 ? num / den : 1 }
      return (ratio(s.gray50.r, s.white.r),
              ratio(s.gray50.g, s.white.g),
              ratio(s.gray50.b, s.white.b))
    }

    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [:] }
    let refBal = balance(ref.samples)

    var result: [String: ColorCorrection] = [:]
    for m in measurements {
      if m.displayID == referenceID { result[m.displayID] = .identity; continue }
      let b = balance(m.samples)

      // Per-channel gain that makes this display's gray-balance match the reference.
      func gain(_ refCh: Double, _ ch: Double) -> Double { ch > 1e-6 ? refCh / ch : 1 }
      var r = gain(refBal.r, b.r)
      var g = gain(refBal.g, b.g)
      var bl = gain(refBal.b, b.b)

      // Damped white-point nudge: compare luminance-normalized white chroma.
      func norm(_ c: RGB) -> (r: Double, g: Double, b: Double) {
        let l = (c.r + c.g + c.b) / 3
        return l > 1e-6 ? (c.r / l, c.g / l, c.b / l) : (1, 1, 1)
      }
      let rw = norm(ref.samples.white), tw = norm(m.samples.white)
      func wp(_ refCh: Double, _ ch: Double) -> Double {
        let full = refCh > 1e-6 ? ch / refCh : 1
        return 1 + (full - 1) * whitePointDamping
      }
      r *= wp(rw.r, tw.r); g *= wp(rw.g, tw.g); bl *= wp(rw.b, tw.b)

      // We can only attenuate (gamma max <= 1): normalize so the brightest channel is 1.
      let peak = max(r, max(g, bl))
      if peak > 1e-6 { r /= peak; g /= peak; bl /= peak }

      result[m.displayID] = ColorCorrection(redGain: r, greenGain: g, blueGain: bl, gamma: 1)
    }
    return result
  }
}
