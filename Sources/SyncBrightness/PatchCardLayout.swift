import CoreGraphics

/// Canonical patch-card geometry in normalized coordinates (0...1, origin bottom-left).
/// Shared by the macOS renderer (PatchCardWindow) and the analyzer so they agree.
enum PatchCardLayout {
  static let columns = 3
  static let rows = 2
  /// Grid inset from the card edges (fiducials live in the outer margin).
  static let inset = 0.12

  enum PatchRole { case white, gray50, gray25, red, green, blue }

  /// Row 1 (top): white, gray50, gray25. Row 0 (bottom): red, green, blue.
  static func role(col: Int, row: Int) -> PatchRole {
    switch (col, row) {
    case (0, 1): return .white
    case (1, 1): return .gray50
    case (2, 1): return .gray25
    case (0, 0): return .red
    case (1, 0): return .green
    default:     return .blue
    }
  }

  static var allRoles: [PatchRole] {
    [.white, .gray50, .gray25, .red, .green, .blue]
  }

  /// Normalized center of a grid cell.
  static func cellCenter(col: Int, row: Int) -> CGPoint {
    let u = inset + (Double(col) + 0.5) / Double(columns) * (1 - 2 * inset)
    let v = inset + (Double(row) + 0.5) / Double(rows) * (1 - 2 * inset)
    return CGPoint(x: u, y: v)
  }

  /// Normalized rect of a grid cell (for the renderer).
  static func cellRect(col: Int, row: Int) -> CGRect {
    let w = (1 - 2 * inset) / Double(columns)
    let h = (1 - 2 * inset) / Double(rows)
    let x = inset + Double(col) * w
    let y = inset + Double(row) * h
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// The sRGB color the renderer should fill for a role.
  static func fillColor(_ role: PatchRole) -> (r: Double, g: Double, b: Double) {
    switch role {
    case .white:  return (1, 1, 1)
    case .gray50: return (0.5, 0.5, 0.5)
    case .gray25: return (0.25, 0.25, 0.25)
    case .red:    return (1, 0, 0)
    case .green:  return (0, 1, 0)
    case .blue:   return (0, 0, 1)
    }
  }
}
