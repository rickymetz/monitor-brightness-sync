import Foundation

struct DisplayMeasurement {
  let displayID: String
  let samples: PatchSamples
}

/// Locked-camera color matcher. All photos in a session share ONE fixed camera
/// transform G (the iOS app locks WB + exposure once), so the per-channel ratio
/// of two displays' measured whites equals the ratio of their emitted whites — G
/// cancels.
///
/// We match BOTH chroma and luminance: the only white every display can reach with
/// attenuate-only controls is the per-channel MINIMUM of their measured whites
/// (the "common floor"). Driving every display — including the reference — to that
/// white equalizes color and brightness together. This dims the brighter display
/// (often the built-in) down to the dimmer one; that's the deliberate trade for a
/// true match (chosen over leaving brightness to the brightness-sync feature).
enum ColorMatcher {
  /// Displayed input levels of the gray ramp, mapped to gray25 / gray50 / white.
  static let rampLevels: [Double] = [0.25, 0.5, 0.8]

  static func corrections(measurements: [DisplayMeasurement],
                          referenceID: String) -> [String: ColorCorrection] {
    guard !measurements.isEmpty else { return [:] }
    let refGamma = measurements.first(where: { $0.displayID == referenceID })
      .map { effectiveGamma($0.samples) } ?? 1

    // Common achievable white: per-channel min across all displays' measured whites.
    let whites = measurements.map { $0.samples.white }
    let target = RGB(r: whites.map { $0.r }.min() ?? 0,
                     g: whites.map { $0.g }.min() ?? 0,
                     b: whites.map { $0.b }.min() ?? 0)

    // Attenuate channel to the floor; dead channel (no emission) → leave alone.
    func gain(_ floorC: Double, _ measuredC: Double) -> Double {
      measuredC > 1e-6 ? min(1, floorC / measuredC) : 1
    }

    var result: [String: ColorCorrection] = [:]
    for m in measurements {
      let w = m.samples.white
      // Corrective gamma so each display's tone curve matches the reference's. The
      // camera's own response is meant to cancel in the ratio — but only if the
      // capture is LINEAR. On the 8-bit sRGB fallback the fit overshoots and
      // over-darkens midtones (the dominant cause of a residual brightness gap), so
      // the clamp is deliberately tight. Widen once linear RAW is confirmed.
      let tgtGamma = effectiveGamma(m.samples)
      let gammaCorr = tgtGamma > 1e-3 ? min(1.4, max(0.75, refGamma / tgtGamma)) : 1
      result[m.displayID] = ColorCorrection(redGain: gain(target.r, w.r),
                                            greenGain: gain(target.g, w.g),
                                            blueGain: gain(target.b, w.b),
                                            gamma: gammaCorr)
    }
    return result
  }

  // MARK: - Primaries / matrix (diagnostics today, ICC-correction seam tomorrow)

  /// 3×3 matrix that maps the TARGET panel's measured RGB onto the REFERENCE
  /// panel's measured RGB, solved from the three measured primaries: with the
  /// camera locked, columns are the target primaries (T) and reference primaries
  /// (R), so M = R · T⁻¹. This is the full cross-channel correction a diagonal
  /// gain/gamma cannot express; we don't *apply* it yet (the gamma-table/DDC path
  /// is diagonal-only) but we compute it to (a) quantify the residual a diagonal
  /// leaves behind and (b) hand a ready-made matrix to a future ICC-profile path.
  static func primaryMatrix(target t: PatchSamples, reference r: PatchSamples) -> Matrix3? {
    let T = Matrix3(columns: t.red, t.green, t.blue)
    let R = Matrix3(columns: r.red, r.green, r.blue)
    guard let tInv = T.inverse else { return nil }
    return R * tInv
  }

  /// Per-display quality of the match, in perceptual ΔE2000 (see DeltaE for the
  /// camera-space approximation caveat). `diagonalDeltaE` is the mean residual
  /// after the diagonal correction we actually apply; `matrixDeltaE` is the mean
  /// residual a full 3×3 correction would leave — the headroom an ICC path buys.
  struct MatchReport: Equatable {
    let displayID: String
    let diagonalDeltaE: Double
    let matrixDeltaE: Double
    let worstPatch: String
  }

  /// Evaluate each non-reference display against the reference, reporting the
  /// residual ΔE2000 left by the diagonal correction vs. a full 3×3 matrix.
  /// Pure; intended for the calibration UI's quality readout and for deciding
  /// when the diagonal is "good enough" vs. when ICC matrix correction is worth it.
  static func report(measurements: [DisplayMeasurement], referenceID: String,
                     corrections: [String: ColorCorrection]) -> [MatchReport] {
    guard let ref = measurements.first(where: { $0.displayID == referenceID }) else { return [] }
    let patches: [(String, KeyPath<PatchSamples, RGB>)] = [
      ("white", \.white), ("gray50", \.gray50), ("gray25", \.gray25),
      ("red", \.red), ("green", \.green), ("blue", \.blue),
    ]
    let cRef = corrections[referenceID] ?? .identity
    var out: [MatchReport] = []
    for m in measurements where m.displayID != referenceID {
      let c = corrections[m.displayID] ?? .identity
      let matrix = primaryMatrix(target: m.samples, reference: ref.samples)

      // Apply a display's diagonal gains (gamma is ~no-op at the full-on
      // primaries/white that dominate chroma, so we model gains only). Both the
      // target AND the reference now get corrected toward the common white, so we
      // compare corrected-to-corrected.
      func diag(_ p: RGB, _ k: ColorCorrection) -> RGB {
        RGB(r: min(1, max(0, p.r * k.redGain)),
            g: min(1, max(0, p.g * k.greenGain)),
            b: min(1, max(0, p.b * k.blueGain)))
      }
      // Residual is CHROMA only (luminance equalized): this metric isolates the
      // hue/chroma error a diagonal can't remove vs. a full 3×3 — the luminance
      // match is verified separately (SideBySideMetric's brightness term).
      func chromaDelta(_ a: RGB, _ b: RGB) -> Double {
        func lum(_ c: RGB) -> Double { (c.r + c.g + c.b) / 3 }
        func atMid(_ c: RGB) -> RGB { let l = lum(c); return l > 1e-6 ? RGB(r: c.r * 0.5 / l, g: c.g * 0.5 / l, b: c.b * 0.5 / l) : c }
        return DeltaE.between(atMid(a), atMid(b))
      }
      var diagSum = 0.0, matSum = 0.0, worst = 0.0, worstName = "—"
      for (name, kp) in patches {
        let tgt = m.samples[keyPath: kp], refP = ref.samples[keyPath: kp]
        let refCorrected = diag(refP, cRef)
        let dD = chromaDelta(diag(tgt, c), refCorrected)
        // A full 3×3 maps the target onto the reference's primaries; compare it to
        // the same corrected reference to show the headroom over the diagonal.
        let dM = matrix.map { chromaDelta(diag($0 * tgt, cRef), refCorrected) } ?? dD
        diagSum += dD; matSum += dM
        if dD > worst { worst = dD; worstName = name }
      }
      let n = Double(patches.count)
      out.append(MatchReport(displayID: m.displayID,
                             diagonalDeltaE: diagSum / n,
                             matrixDeltaE: matSum / n,
                             worstPatch: worstName))
    }
    return out
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
