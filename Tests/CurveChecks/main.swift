// Framework-free checks for BrightnessCurve — runs with only the Command Line
// Tools (XCTest/swift-testing need full Xcode). Built by ./run-tests.sh, which
// compiles this together with the real Sources/.../BrightnessCurve.swift, so it
// exercises the actual implementation.
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
  if condition {
    print("  ✓ \(message)")
  } else {
    print("  ✗ \(message)")
    failures += 1
  }
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

print("BrightnessCurve checks")

// Default curve anchors: built-in [0.15...1.0] -> external [0...1].
let d = BrightnessCurve.default
check(approx(d.external(for: 0.15), 0), "default: 15% built-in -> 0% external (floor)")
check(approx(d.external(for: 1.0), 1), "default: 100% -> 100%")
check(approx(d.external(for: 0.575), 0.5), "default: midpoint interpolates to 50%")
check(approx(d.external(for: 0.05), 0), "below floor clamps to 0")
check(approx(d.zeroBuiltin, 0.15), "zeroBuiltin reports the floor")

// Multi-point interpolation.
let m = BrightnessCurve(points: [
  CurvePoint(builtin: 0.15, external: 0.0),
  CurvePoint(builtin: 0.5, external: 0.25),
  CurvePoint(builtin: 1.0, external: 1.0),
])
check(approx(m.external(for: 0.5), 0.25), "multi: exact point")
check(approx(m.external(for: 0.75), 0.625), "multi: halfway 0.5->1.0 segment")

// Clamping above the top point.
let t = BrightnessCurve(points: [
  CurvePoint(builtin: 0.2, external: 0.1),
  CurvePoint(builtin: 0.8, external: 0.9),
])
check(approx(t.external(for: 1.0), 0.9), "above top clamps to last")
check(approx(t.external(for: 0.1), 0.1), "below first clamps to first")

// addOrUpdate replaces within tolerance and keeps sorted order.
var u = BrightnessCurve.default
let before = u.points.count
u.addOrUpdate(builtin: 0.15, external: 0.2)
check(u.points.count == before, "addOrUpdate replaces near-duplicate (no new point)")
check(approx(u.external(for: 0.15), 0.2), "addOrUpdate updated the value")
u.addOrUpdate(builtin: 0.5, external: 0.3)
check(u.points.map(\.builtin) == u.points.map(\.builtin).sorted(), "points stay sorted")

// Empty curve mirrors 1:1.
var e = BrightnessCurve.default
e.removeAll()
check(approx(e.external(for: 0.42), 0.42), "empty curve mirrors 1:1")

// Codable round-trip.
if let data = try? JSONEncoder().encode(d),
   let decoded = try? JSONDecoder().decode(BrightnessCurve.self, from: data) {
  check(decoded.points == d.points, "Codable round-trip preserves points")
} else {
  check(false, "Codable round-trip")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
