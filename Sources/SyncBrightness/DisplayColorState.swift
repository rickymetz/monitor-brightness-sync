import CoreGraphics

/// One channel's CGSetDisplayTransferByFormula triple.
struct Channel: Equatable {
  var min: Float
  var max: Float
  var gamma: Float
}

/// Owns per-display dim factor + color correction, and composes them into a
/// single gamma-table write. Replaces GammaDimmer (same `set(_:factor:)`/`reset()`
/// API so existing SyncController call sites are unchanged). Color correction and
/// sub-floor dimming therefore share one transfer write per display.
final class DisplayColorState {
  private var dims: [CGDirectDisplayID: Double] = [:]
  private var corrections: [CGDirectDisplayID: ColorCorrection] = [:]

  struct Formula: Equatable { var red, green, blue: Channel }

  /// Pure: combine a dim factor (0...1 luminance multiplier) with a correction.
  static func formula(dim: Double, correction c: ColorCorrection) -> Formula {
    func ch(_ gain: Double) -> Channel {
      Channel(min: 0,
              max: Float(max(0, min(1, dim * gain))),
              gamma: Float(max(0.01, c.gamma)))
    }
    return Formula(red: ch(c.redGain), green: ch(c.greenGain), blue: ch(c.blueGain))
  }

  /// Dim a display (1 = no dimming). Preserves GammaDimmer's contract.
  func set(_ id: CGDirectDisplayID?, factor: Double) {
    guard let id else { return }
    dims[id] = max(0, min(1, factor))
    apply(id)
  }

  /// Set the per-display color correction (.identity to clear).
  func setCorrection(_ id: CGDirectDisplayID?, _ c: ColorCorrection) {
    guard let id else { return }
    corrections[id] = c
    apply(id)
  }

  /// Restore color-profile gamma everywhere (call on quit), then re-apply any
  /// non-trivial state. CGDisplayRestoreColorSyncSettings resets every display.
  func reset() {
    CGDisplayRestoreColorSyncSettings()
    for id in Set(dims.keys).union(corrections.keys) { apply(id, restoring: true) }
  }

  private func isTrivial(_ id: CGDirectDisplayID) -> Bool {
    (dims[id] ?? 1) >= 0.999 && (corrections[id] ?? .identity) == .identity
  }

  private func apply(_ id: CGDirectDisplayID, restoring: Bool = false) {
    let dim = dims[id] ?? 1
    let c = corrections[id] ?? .identity
    if isTrivial(id) {
      if !restoring { restoreOthers(except: nil) } // clear this display back to profile
      return
    }
    let f = DisplayColorState.formula(dim: dim, correction: c)
    CGSetDisplayTransferByFormula(id,
      f.red.min, f.red.max, f.red.gamma,
      f.green.min, f.green.max, f.green.gamma,
      f.blue.min, f.blue.max, f.blue.gamma)
  }

  // Clearing one display requires a global restore (no per-display restore API),
  // then re-applying the others that should stay non-trivial.
  private func restoreOthers(except keep: CGDirectDisplayID?) {
    CGDisplayRestoreColorSyncSettings()
    for id in Set(dims.keys).union(corrections.keys) where id != keep && !isTrivial(id) {
      apply(id, restoring: true)
    }
  }
}
