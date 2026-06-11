import Foundation

/// Pure color math for the 3×3 (ICC) correction path.
///
/// Our iPhone "colorimeter" only measures *relative* color (camera-linear RGB), not
/// absolute XYZ — so we can't build a colorimetric profile for a display on its own.
/// But we CAN anchor on the built-in display's factory ICC profile, which Apple
/// calibrates and which gives us a trustworthy reference RGB→XYZ (`P_ref`). Composing
/// the measured camera matrices onto it yields the target panel's primaries in real
/// XYZ — exactly what an ICC matrix/TRC display profile encodes.
///
/// Derivation (camera transform cancels because every shot shares one locked camera):
///   A target input x emits, to the camera, `C_tgt · x`. The reference input that
///   looks identical emits `C_ref · y` with `C_ref·y = C_tgt·x`, so in reference-RGB
///   coordinates the target behaves as `B = C_ref⁻¹ · C_tgt`. Mapping reference-RGB to
///   XYZ with the reference's calibrated `P_ref` gives the target's primaries in XYZ:
///       M_xyz = P_ref · C_ref⁻¹ · C_tgt
/// Installing M_xyz as the target display's profile lets ColorSync render content so
/// the target matches the reference. This is the full cross-channel correction a
/// diagonal gain/gamma cannot express (which is why RAW exposed the residual cast).
enum DisplayProfileMath {
  /// Camera-linear response matrix of a display: columns are the measured camera RGB
  /// of that display's full-on red, green, blue primaries.
  static func cameraMatrix(_ s: PatchSamples) -> Matrix3 {
    Matrix3(columns: s.red, s.green, s.blue)
  }

  /// The target panel's primaries as an RGB→XYZ matrix, anchored on the reference
  /// panel's calibrated RGB→XYZ. Returns nil if the reference camera matrix is
  /// singular (degenerate measurement).
  static func targetRGBtoXYZ(referenceRGBtoXYZ pRef: Matrix3,
                             referenceSamples ref: PatchSamples,
                             targetSamples tgt: PatchSamples) -> Matrix3? {
    let cRef = cameraMatrix(ref)
    let cTgt = cameraMatrix(tgt)
    guard let cRefInv = cRef.inverse else { return nil }
    return pRef * cRefInv * cTgt
  }

  /// Convenience: the target white point in XYZ (M_xyz applied to full white).
  static func whiteXYZ(_ mXYZ: Matrix3) -> RGB {
    mXYZ * RGB(r: 1, g: 1, b: 1)
  }
}
