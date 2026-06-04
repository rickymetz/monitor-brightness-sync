import Foundation

private func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }

struct CurvePoint: Codable, Equatable {
  var builtin: Double // 0...1 built-in brightness fraction
  var external: Double // 0...1 external brightness fraction that visually matches
}

/// A calibration mapping from built-in brightness to the external brightness
/// that looks the same. Stored as anchor points; values in between are
/// piecewise-linearly interpolated. This makes no assumption about either
/// panel's brightness curve — the user supplies the match points by eye.
struct BrightnessCurve: Codable {
  private(set) var points: [CurvePoint]

  init(points: [CurvePoint]) {
    self.points = points.sorted { $0.builtin < $1.builtin }
  }

  /// Seeded with the previously calibrated 15% floor: external bottoms out at
  /// 15% built-in and tracks 1:1 to the top.
  static let `default` = BrightnessCurve(points: [
    CurvePoint(builtin: 0.15, external: 0.0),
    CurvePoint(builtin: 1.0, external: 1.0),
  ])

  /// Add a match point, or replace an existing one at the same built-in level.
  mutating func addOrUpdate(builtin: Double, external: Double, tolerance: Double = 0.03) {
    let b = clamp01(builtin)
    let e = clamp01(external)
    if let index = points.firstIndex(where: { abs($0.builtin - b) <= tolerance }) {
      points[index] = CurvePoint(builtin: b, external: e)
    } else {
      points.append(CurvePoint(builtin: b, external: e))
    }
    points.sort { $0.builtin < $1.builtin }
  }

  mutating func removeAll() {
    points = []
  }

  /// The highest built-in fraction at which the external is mapped to 0 (its
  /// DDC floor). Below this, sub-floor gamma dimming can take over.
  var zeroBuiltin: Double {
    let zeros = points.filter { $0.external <= 0.0001 }
    return zeros.map(\.builtin).max() ?? 0
  }

  /// External brightness fraction that matches the given built-in fraction.
  func external(for builtin: Double) -> Double {
    let f = clamp01(builtin)
    guard let first = points.first, let last = points.last else {
      return f // no calibration: mirror 1:1
    }
    if f <= first.builtin { return first.external }
    if f >= last.builtin { return last.external }
    for i in 1 ..< points.count {
      let a = points[i - 1]
      let b = points[i]
      if f <= b.builtin {
        let span = b.builtin - a.builtin
        let t = span > 0 ? (f - a.builtin) / span : 0
        return a.external + t * (b.external - a.external)
      }
    }
    return last.external
  }
}
