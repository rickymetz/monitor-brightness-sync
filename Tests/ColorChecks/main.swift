import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
  if !cond { print("FAIL: \(msg)"); failures += 1 } else { print("ok: \(msg)") }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

// ColorCorrection.identity is a no-op
let id = ColorCorrection.identity
check(id.redGain == 1 && id.greenGain == 1 && id.blueGain == 1 && id.gamma == 1, "identity is unit")

// Codable round-trips
let c = ColorCorrection(redGain: 0.9, greenGain: 1.0, blueGain: 0.8, gamma: 1.0)
let data = try! JSONEncoder().encode(c)
let back = try! JSONDecoder().decode(ColorCorrection.self, from: data)
check(back == c, "ColorCorrection codable round-trip")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
