import CoreGraphics

/// Dims a display below its DDC floor using the CoreGraphics gamma table, so an
/// external can approach the built-in's near-black. Only touches gamma while a
/// display is actually dimmed, and restores the colour-profile gamma otherwise.
final class GammaDimmer {
  private var factors: [CGDirectDisplayID: Float] = [:]

  /// `factor` is a 0...1 luminance multiplier (1 = no dimming).
  func set(_ id: CGDirectDisplayID?, factor: Double) {
    guard let id else { return }
    let f = Float(max(0.0, min(1.0, factor)))
    let wasDimmed = (factors[id] ?? 1) < 0.999

    if f < 0.999 {
      factors[id] = f
      CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
    } else if wasDimmed {
      factors[id] = 1
      restoreToProfiles()
    }
  }

  /// Forget displays we no longer manage. Nothing to restore — they're gone —
  /// but leaving them in the table means restoreToProfiles() keeps re-applying
  /// their dimming, and macOS recycles display ids.
  func prune(keeping ids: Set<CGDirectDisplayID>) {
    factors = factors.filter { ids.contains($0.key) }
  }

  /// The factor currently applied to a display, if we're dimming it.
  func factor(for id: CGDirectDisplayID?) -> Double? {
    guard let id, let f = factors[id] else { return nil }
    return Double(f)
  }

  /// Remove all dimming and restore colour-profile gamma (call on quit).
  func reset() {
    factors.removeAll()
    CGDisplayRestoreColorSyncSettings()
  }

  // CGDisplayRestoreColorSyncSettings resets every display, so re-apply any
  // displays that should still be dimmed.
  private func restoreToProfiles() {
    CGDisplayRestoreColorSyncSettings()
    for (id, f) in factors where f < 0.999 {
      CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
    }
  }
}
