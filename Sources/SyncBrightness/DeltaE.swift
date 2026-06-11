import Foundation

/// CIE L*a*b* triple (D65 reference white).
struct Lab: Equatable {
  var L: Double
  var a: Double
  var b: Double
}

/// Perceptual color difference (CIEDE2000) and the linear-RGB → XYZ → Lab
/// pipeline it needs.
///
/// IMPORTANT — color space assumption. Our measurements are *camera-space* linear
/// RGB (the locked camera's response), not absolute colorimetric values. We do
/// NOT have a camera→XYZ calibration matrix, so converting to Lab is an
/// approximation: we treat the measured linear RGB as if it lived in linear sRGB
/// (Rec.709 primaries, D65). This is deliberately a *relative* objective — both
/// displays are measured through the same camera transform, so a perceptually
/// weighted distance between the two is far better than a raw RGB L1 difference
/// for driving a match, even though it is not an absolute ΔE against a standard
/// observer. See ColorMatcher / SideBySideMetric for how it's used.
enum DeltaE {
  // Linear sRGB (Rec.709 / D65) → CIE XYZ.
  static func xyz(fromLinearRGB c: RGB) -> (x: Double, y: Double, z: Double) {
    let r = c.r, g = c.g, b = c.b
    let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    return (x, y, z)
  }

  // D65 reference white (Y normalized to 1).
  private static let wn = (x: 0.95047, y: 1.0, z: 1.08883)

  static func lab(fromLinearRGB c: RGB) -> Lab {
    let (x, y, z) = xyz(fromLinearRGB: c)
    func f(_ t: Double) -> Double {
      let d: Double = 6.0 / 29.0
      return t > d * d * d ? Foundation.cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
    }
    let fx = f(x / wn.x), fy = f(y / wn.y), fz = f(z / wn.z)
    return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
  }

  /// CIEDE2000 color difference between two Lab values. Implements the full
  /// formulation (Sharma, Wu & Dalal 2005) including the hue-rotation term.
  static func ciede2000(_ lab1: Lab, _ lab2: Lab) -> Double {
    let kL = 1.0, kC = 1.0, kH = 1.0
    let L1 = lab1.L, a1 = lab1.a, b1 = lab1.b
    let L2 = lab2.L, a2 = lab2.a, b2 = lab2.b

    let C1 = (a1 * a1 + b1 * b1).squareRoot()
    let C2 = (a2 * a2 + b2 * b2).squareRoot()
    let Cbar = (C1 + C2) / 2
    let Cbar7 = pow(Cbar, 7)
    let G = 0.5 * (1 - (Cbar7 / (Cbar7 + pow(25.0, 7))).squareRoot())

    let a1p = (1 + G) * a1
    let a2p = (1 + G) * a2
    let C1p = (a1p * a1p + b1 * b1).squareRoot()
    let C2p = (a2p * a2p + b2 * b2).squareRoot()

    func hp(_ b: Double, _ ap: Double) -> Double {
      if b == 0 && ap == 0 { return 0 }
      let h = atan2(b, ap) * 180 / .pi
      return h < 0 ? h + 360 : h
    }
    let h1p = hp(b1, a1p)
    let h2p = hp(b2, a2p)

    let dLp = L2 - L1
    let dCp = C2p - C1p

    var dhp: Double
    if C1p * C2p == 0 {
      dhp = 0
    } else if abs(h2p - h1p) <= 180 {
      dhp = h2p - h1p
    } else if h2p - h1p > 180 {
      dhp = h2p - h1p - 360
    } else {
      dhp = h2p - h1p + 360
    }
    let dHp = 2 * (C1p * C2p).squareRoot() * sin(dhp * .pi / 180 / 2)

    let Lbarp = (L1 + L2) / 2
    let Cbarp = (C1p + C2p) / 2

    var hbarp: Double
    if C1p * C2p == 0 {
      hbarp = h1p + h2p
    } else if abs(h1p - h2p) <= 180 {
      hbarp = (h1p + h2p) / 2
    } else if h1p + h2p < 360 {
      hbarp = (h1p + h2p + 360) / 2
    } else {
      hbarp = (h1p + h2p - 360) / 2
    }

    let T = 1
      - 0.17 * cos((hbarp - 30) * .pi / 180)
      + 0.24 * cos((2 * hbarp) * .pi / 180)
      + 0.32 * cos((3 * hbarp + 6) * .pi / 180)
      - 0.20 * cos((4 * hbarp - 63) * .pi / 180)

    let dTheta = 30 * exp(-pow((hbarp - 275) / 25, 2))
    let Cbarp7 = pow(Cbarp, 7)
    let Rc = 2 * (Cbarp7 / (Cbarp7 + pow(25.0, 7))).squareRoot()
    let Sl = 1 + (0.015 * pow(Lbarp - 50, 2)) / (20 + pow(Lbarp - 50, 2)).squareRoot()
    let Sc = 1 + 0.045 * Cbarp
    let Sh = 1 + 0.015 * Cbarp * T
    let Rt = -sin(2 * dTheta * .pi / 180) * Rc

    let termL = dLp / (kL * Sl)
    let termC = dCp / (kC * Sc)
    let termH = dHp / (kH * Sh)
    return (termL * termL + termC * termC + termH * termH + Rt * termC * termH).squareRoot()
  }

  /// Convenience: perceptual distance between two linear-RGB measurements.
  static func between(_ a: RGB, _ b: RGB) -> Double {
    ciede2000(lab(fromLinearRGB: a), lab(fromLinearRGB: b))
  }
}
