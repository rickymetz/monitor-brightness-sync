import Foundation

/// Auto-capture stability gate: fires once the analyzer has located the card on
/// `needed` consecutive frames. A miss resets the streak. Pure + shared.
struct CaptureGate {
  let needed: Int
  private var streak = 0

  init(needed: Int = 5) { self.needed = max(1, needed) }

  /// Returns true exactly when the streak first reaches `needed`.
  mutating func record(found: Bool) -> Bool {
    if found { streak += 1 } else { streak = 0 }
    if streak == needed { return true }
    return false
  }

  mutating func reset() { streak = 0 }
}
