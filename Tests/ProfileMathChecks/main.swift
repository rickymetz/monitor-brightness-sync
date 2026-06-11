import Foundation

// Compiled together with the real DisplayProfileMath/Matrix3/ColorCorrection source.
var failures = 0
func check(_ cond: Bool, _ name: String) {
  print(cond ? "  ✓ \(name)" : "  ✗ \(name)"); if !cond { failures += 1 }
}
func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }
func matClose(_ a: Matrix3, _ b: Matrix3, _ eps: Double = 1e-9) -> Bool {
  for i in 0..<3 { for j in 0..<3 { if !close(a.m[i][j], b.m[i][j], eps) { return false } } }
  return true
}

// A plausible reference RGB→XYZ (sRGB-ish, D65, columns = primary XYZ).
let pRef = Matrix3([[0.4124, 0.3576, 0.1805],
                    [0.2126, 0.7152, 0.0722],
                    [0.0193, 0.1192, 0.9505]])

func samples(red: RGB, green: RGB, blue: RGB) -> PatchSamples {
  PatchSamples(white: RGB(r: 0, g: 0, b: 0), gray50: RGB(r: 0, g: 0, b: 0),
               gray25: RGB(r: 0, g: 0, b: 0), red: red, green: green, blue: blue)
}

print("== identity: target == reference ⇒ M_xyz == P_ref ==")
// Same camera response for both ⇒ the target IS the reference ⇒ profile == reference.
let camRef = samples(red: RGB(r: 0.21, g: 0.16, b: 0.13),
                     green: RGB(r: 0.16, g: 0.35, b: 0.17),
                     blue: RGB(r: 0.13, g: 0.15, b: 0.24))
let mSame = DisplayProfileMath.targetRGBtoXYZ(referenceRGBtoXYZ: pRef,
                                              referenceSamples: camRef, targetSamples: camRef)!
check(matClose(mSame, pRef), "C_tgt == C_ref ⇒ M_xyz == P_ref")

print("== green-biased target shifts its primaries vs reference ==")
// Target reads much greener (like the Dell in raw): its profile must differ from P_ref.
let camTgt = samples(red: RGB(r: 0.35, g: 0.22, b: 0.15),
                     green: RGB(r: 0.22, g: 0.68, b: 0.24),
                     blue: RGB(r: 0.14, g: 0.23, b: 0.42))
let mTgt = DisplayProfileMath.targetRGBtoXYZ(referenceRGBtoXYZ: pRef,
                                             referenceSamples: camRef, targetSamples: camTgt)!
check(!matClose(mTgt, pRef, 1e-3), "different camera response ⇒ different profile")

print("== composition identity: P_ref·C_ref⁻¹·C_tgt round-trips through camera space ==")
// The target's white in XYZ should equal P_ref · (C_ref⁻¹ · cameraWhiteTarget),
// i.e. mapping the target's camera-white into reference-RGB then to XYZ.
let cRef = DisplayProfileMath.cameraMatrix(camRef)
let cTgt = DisplayProfileMath.cameraMatrix(camTgt)
let camWhiteTgt = cTgt * RGB(r: 1, g: 1, b: 1)                 // target full-white in camera space
let inRefRGB = cRef.inverse! * camWhiteTgt                     // expressed in reference-RGB
let expectWhite = pRef * inRefRGB
let gotWhite = DisplayProfileMath.whiteXYZ(mTgt)
check(close(expectWhite.r, gotWhite.r) && close(expectWhite.g, gotWhite.g) && close(expectWhite.b, gotWhite.b),
      "white XYZ consistent with the camera→ref→XYZ chain")

print("== singular reference camera matrix ⇒ nil (degenerate guard) ==")
let degenerate = samples(red: RGB(r: 0.2, g: 0.2, b: 0.2),
                         green: RGB(r: 0.2, g: 0.2, b: 0.2),
                         blue: RGB(r: 0.2, g: 0.2, b: 0.2))   // identical columns ⇒ singular
check(DisplayProfileMath.targetRGBtoXYZ(referenceRGBtoXYZ: pRef,
                                        referenceSamples: degenerate, targetSamples: camTgt) == nil,
      "singular C_ref ⇒ nil")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
