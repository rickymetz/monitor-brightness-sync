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
    let wasTrivial = isTrivial(id)
    dims[id] = max(0, min(1, factor))
    applyTransition(id, wasTrivial: wasTrivial)
  }

  /// Set the per-display color correction (.identity to clear).
  func setCorrection(_ id: CGDirectDisplayID?, _ c: ColorCorrection) {
    guard let id else { return }
    let wasTrivial = isTrivial(id)
    corrections[id] = c
    applyTransition(id, wasTrivial: wasTrivial)
  }

  /// Clear all state and restore color-profile gamma everywhere (call on quit).
  func reset() {
    dims.removeAll()
    corrections.removeAll()
    CGDisplayRestoreColorSyncSettings()
  }

  private func isTrivial(_ id: CGDirectDisplayID) -> Bool {
    (dims[id] ?? 1) >= 0.999 && (corrections[id] ?? .identity) == .identity
  }

  private func applyTransition(_ id: CGDirectDisplayID, wasTrivial: Bool) {
    if isTrivial(id) {
      if !wasTrivial { restoreAndReapply() }   // only on the non-trivial -> trivial edge
    } else {
      writeFormula(id)
    }
  }

  private func writeFormula(_ id: CGDirectDisplayID) {
    let f = DisplayColorState.formula(dim: dims[id] ?? 1, correction: corrections[id] ?? .identity)
    CGSetDisplayTransferByFormula(id,
      f.red.min, f.red.max, f.red.gamma,
      f.green.min, f.green.max, f.green.gamma,
      f.blue.min, f.blue.max, f.blue.gamma)
  }

  // Global restore (no per-display restore API), then re-write the displays that
  // should stay non-trivial.
  private func restoreAndReapply() {
    CGDisplayRestoreColorSyncSettings()
    for id in Set(dims.keys).union(corrections.keys) where !isTrivial(id) { writeFormula(id) }
  }
}
