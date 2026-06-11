import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
  if !condition { failures += 1 }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

print("== ambient CCT → warm/cool bias ==")
check(approx(AmbientBias.warmCool(forKelvin: 6500), 0), "6500K (neutral) → 0 bias")
check(AmbientBias.warmCool(forKelvin: 3000) > 0, "warm room (3000K) → warm (positive) bias")
check(AmbientBias.warmCool(forKelvin: 9000) < 0, "cool room (9000K) → cool (negative) bias")
check(approx(AmbientBias.warmCool(forKelvin: 3000), 1), "3000K → full warm (+1)")
check(approx(AmbientBias.warmCool(forKelvin: 10000), -1), "10000K → full cool (-1)")

print("== clamping & monotonicity ==")
check(approx(AmbientBias.warmCool(forKelvin: 1000), 1), "very warm clamps to +1")
check(approx(AmbientBias.warmCool(forKelvin: 20000), -1), "very cool clamps to -1")
check(AmbientBias.warmCool(forKelvin: 4000) > AmbientBias.warmCool(forKelvin: 5000), "monotonic: warmer → larger bias")
check(approx(AmbientBias.warmCool(forKelvin: 0), 0), "non-positive Kelvin → 0 (guard)")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
