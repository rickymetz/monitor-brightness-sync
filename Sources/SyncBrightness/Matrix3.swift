import Foundation

/// A minimal 3×3 real matrix for primaries-matching color math (RGB→RGB).
/// Stored row-major. Cocoa-free so it stays unit-testable without a device.
struct Matrix3: Equatable {
  /// m[row][col]
  var m: [[Double]]

  init(_ rows: [[Double]]) { self.m = rows }

  /// Build from three column vectors (e.g. the R, G, B primary measurements).
  init(columns c0: RGB, _ c1: RGB, _ c2: RGB) {
    m = [[c0.r, c1.r, c2.r],
         [c0.g, c1.g, c2.g],
         [c0.b, c1.b, c2.b]]
  }

  static let identity = Matrix3([[1, 0, 0], [0, 1, 0], [0, 0, 1]])

  var determinant: Double {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
      - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
      + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
  }

  /// Inverse via the adjugate, or nil if (near-)singular.
  var inverse: Matrix3? {
    let det = determinant
    guard abs(det) > 1e-12 else { return nil }
    let a = m
    let inv = 1.0 / det
    return Matrix3([
      [(a[1][1] * a[2][2] - a[1][2] * a[2][1]) * inv,
       (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * inv,
       (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * inv],
      [(a[1][2] * a[2][0] - a[1][0] * a[2][2]) * inv,
       (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * inv,
       (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * inv],
      [(a[1][0] * a[2][1] - a[1][1] * a[2][0]) * inv,
       (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * inv,
       (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * inv],
    ])
  }

  static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
    var r = [[Double]](repeating: [0, 0, 0], count: 3)
    for i in 0..<3 {
      for j in 0..<3 {
        r[i][j] = lhs.m[i][0] * rhs.m[0][j] + lhs.m[i][1] * rhs.m[1][j] + lhs.m[i][2] * rhs.m[2][j]
      }
    }
    return Matrix3(r)
  }

  /// Apply to an RGB column vector.
  static func * (lhs: Matrix3, v: RGB) -> RGB {
    RGB(r: lhs.m[0][0] * v.r + lhs.m[0][1] * v.g + lhs.m[0][2] * v.b,
        g: lhs.m[1][0] * v.r + lhs.m[1][1] * v.g + lhs.m[1][2] * v.b,
        b: lhs.m[2][0] * v.r + lhs.m[2][1] * v.g + lhs.m[2][2] * v.b)
  }
}
