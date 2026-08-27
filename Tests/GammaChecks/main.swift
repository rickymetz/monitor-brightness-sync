// Framework-free checks for the gamma dimming clamp — runs with only the
// Command Line Tools (XCTest/swift-testing need full Xcode). Built by
// ./run-tests.sh, which compiles this together with the real
// Sources/.../GammaDimmer.swift, so it exercises the actual implementation.
//
// This is the "blackout clamp" case from the design doc: a display we can only
// reach through the gamma table must never go fully black, because the control
// that undoes the dimming is on that screen. It applies to displays with no DDC
// channel at all AND to DDC displays whose writes are refused — in both cases
// there is no backlight answering us, so "allow blackout" must not reach here.
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

print("GammaDimmer clamp checks")

// 1. The floor holds, whatever the requested level.
do {
  check(GammaDimmer.clampedFactor(for: 0.0) == GammaDimmer.minFactor, "a zero level clamps to the floor")
  check(GammaDimmer.clampedFactor(for: -1.0) == GammaDimmer.minFactor, "a negative level clamps to the floor")
  check(GammaDimmer.clampedFactor(for: 0.01) == GammaDimmer.minFactor, "below the floor clamps to the floor")
  check(GammaDimmer.minFactor > 0, "the floor is not black")
}

// 2. Above the floor, the level passes through; above 1 it saturates.
do {
  check(GammaDimmer.clampedFactor(for: 0.5) == 0.5, "a level above the floor passes through")
  check(GammaDimmer.clampedFactor(for: 1.0) == 1.0, "full brightness passes through")
  check(GammaDimmer.clampedFactor(for: 2.0) == 1.0, "a level above 1 saturates at 1")
}

// 3. The case that caused the bug: the default curve maps every built-in level
//    at or below its zero point to exactly 0. A software-dimmed display driven
//    from that output must still stay visible — and "allow blackout" cannot
//    change that, because the clamp takes no such parameter to begin with.
do {
  let curveOutputAtLowBuiltin = 0.0 // BrightnessCurve.default.external(for: 0.15)
  let factor = GammaDimmer.clampedFactor(for: curveOutputAtLowBuiltin)
  check(factor >= GammaDimmer.minFactor, "a curve output of 0 still leaves a readable screen")
  check(factor > 0, "no path through the clamp reaches black")
}

// 4. Monotonic across the range: dimmer input never yields a brighter panel.
do {
  var monotonic = true
  var previous = GammaDimmer.clampedFactor(for: 0)
  for step in 1 ... 100 {
    let factor = GammaDimmer.clampedFactor(for: Double(step) / 100.0)
    if factor < previous { monotonic = false }
    if factor < GammaDimmer.minFactor { monotonic = false }
    previous = factor
  }
  check(monotonic, "the clamp is monotonic and never dips below the floor")
}

print(failures == 0 ? "\nAll GammaDimmer clamp checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
