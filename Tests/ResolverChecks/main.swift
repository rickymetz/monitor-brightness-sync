// Framework-free checks for DisplayResolver — runs with only the Command Line
// Tools (XCTest/swift-testing need full Xcode). Built by ./run-tests.sh, which
// compiles this together with the real Sources/.../DisplayResolver.swift, so it
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

/// The DisplayLink monitor on the machine this feature was written for.
func displayLink(id: UInt32 = 4) -> CGDisplayCandidate {
  CGDisplayCandidate(id: id, vendor: 10635, model: 10049, serial: 244, unit: 3, name: "E27FP1K")
}

print("DisplayResolver checks")

// 1. The affected setup: no DDC displays at all, one DisplayLink monitor.
do {
  let r = DisplayResolver.resolve(ddc: [], cg: [displayLink()])
  check(r.ddc.isEmpty, "no DDC displays -> no assignments")
  check(r.software.count == 1, "the unclaimed display is software-only")
  check(r.software.first?.key == "sw-10635-10049-244", "identity key is sw-vendor-model-serial")
  check(r.software.first?.name == "E27FP1K", "name comes from the screen-name cache")
  check(r.software.first?.cgID == 4, "software display keeps its CoreGraphics id")
  check(r.software.first?.prefersDefaultDisabled == false, "a real monitor enrolls enabled")
}

// 2. Regression: a DDC monitor plus a software display, with the software
//    display FIRST in connection order. Positional assignment alone would hand
//    the DDC monitor the DisplayLink's id and dim the wrong screen.
do {
  let ddcMonitor = CGDisplayCandidate(id: 9, vendor: 7789, model: 22881, serial: 55555, unit: 1, name: "LG HDR 4K")
  let r = DisplayResolver.resolve(ddc: [DDCCandidate(serial: 55555, model: 22881)],
                                  cg: [displayLink(), ddcMonitor])
  check(r.ddc == [9], "serial match binds the DDC monitor to its own display")
  check(r.software.map(\.cgID) == [4], "the DisplayLink display is left as software-only")
}

// 3. Product id breaks the tie when the EDID serial is unreported.
do {
  let ddcMonitor = CGDisplayCandidate(id: 9, vendor: 7789, model: 22881, serial: 0, unit: 1, name: "LG HDR 4K")
  let r = DisplayResolver.resolve(ddc: [DDCCandidate(serial: 0, model: 22881)],
                                  cg: [displayLink(), ddcMonitor])
  check(r.ddc == [9], "product id match binds the DDC monitor correctly")
  check(r.software.map(\.cgID) == [4], "the DisplayLink display is still software-only")
}

// 4. Two identical monitors are told apart by serial, not by order.
do {
  let a = CGDisplayCandidate(id: 7, vendor: 7789, model: 22881, serial: 111, unit: 1, name: "LG HDR 4K")
  let b = CGDisplayCandidate(id: 8, vendor: 7789, model: 22881, serial: 222, unit: 2, name: "LG HDR 4K")
  let r = DisplayResolver.resolve(ddc: [DDCCandidate(serial: 222, model: 22881),
                                        DDCCandidate(serial: 111, model: 22881)],
                                  cg: [a, b])
  check(r.ddc == [8, 7], "identical monitors resolve by serial, ignoring order")
  check(r.software.isEmpty, "nothing left over")
}

// 5. Ambiguous product id falls through to positional rather than guessing.
do {
  let a = CGDisplayCandidate(id: 7, vendor: 7789, model: 22881, serial: 0, unit: 1, name: "LG HDR 4K")
  let b = CGDisplayCandidate(id: 8, vendor: 7789, model: 22881, serial: 0, unit: 2, name: "LG HDR 4K")
  let r = DisplayResolver.resolve(ddc: [DDCCandidate(serial: 0, model: 22881),
                                        DDCCandidate(serial: 0, model: 22881)],
                                  cg: [a, b])
  check(r.ddc == [7, 8], "two matches is not a tiebreak — fall back to connection order")
  check(r.software.isEmpty, "nothing left over")
}

// 6. More DDC displays than CoreGraphics displays: unresolved, not crashed.
do {
  let a = CGDisplayCandidate(id: 7, vendor: 7789, model: 22881, serial: 0, unit: 1, name: nil)
  let r = DisplayResolver.resolve(ddc: [DDCCandidate(serial: 0, model: 0),
                                        DDCCandidate(serial: 0, model: 0)],
                                  cg: [a])
  check(r.ddc == [7, nil], "a DDC display with no display left resolves to nil")
  check(r.software.isEmpty, "nothing left over")
}

// 7. Apple-vendor displays (AirPlay targets, Sidecar iPads) enroll disabled.
do {
  let appleTV = CGDisplayCandidate(id: 12, vendor: 0x610, model: 99, serial: 3, unit: 4, name: "Living Room")
  let r = DisplayResolver.resolve(ddc: [], cg: [appleTV])
  check(r.software.first?.prefersDefaultDisabled == true, "Apple-vendor display enrolls disabled")
  check(r.software.first?.key == "sw-1552-99-3", "Apple-vendor display still gets a key")
}

// 8. No EDID identity at all: keys must still differ between two such panels.
do {
  let a = CGDisplayCandidate(id: 20, vendor: 0, model: 0, serial: 0, unit: 5, name: "Acme Panel")
  let b = CGDisplayCandidate(id: 21, vendor: 0, model: 0, serial: 0, unit: 6, name: "Acme Panel")
  let r = DisplayResolver.resolve(ddc: [], cg: [a, b])
  check(r.software.count == 2, "both enroll")
  check(r.software[0].key != r.software[1].key, "identical blank EDIDs do not share a profile")
  check(r.software[0].key == "sw-0-0-0-Acme-Panel-5", "blank EDID key falls back to name and unit")
}

// 9. A missing screen name degrades to a placeholder rather than an empty label.
do {
  let unnamed = CGDisplayCandidate(id: 30, vendor: 1, model: 2, serial: 3, unit: 7, name: nil)
  let r = DisplayResolver.resolve(ddc: [], cg: [unnamed])
  check(r.software.first?.name == "External display", "cold name cache yields a placeholder")
}

// 10. Two identical panels on one dock: a real vendor and model, but serial 0.
//     Their keys become MonitorState.id, which the disabled/seen sets, the
//     per-monitor slider lookup and the control window's row ids all assume is
//     unique — a shared key means toggling one twin toggles both.
do {
  let a = CGDisplayCandidate(id: 40, vendor: 10635, model: 10049, serial: 0, unit: 3, name: "E27FP1K")
  let b = CGDisplayCandidate(id: 41, vendor: 10635, model: 10049, serial: 0, unit: 4, name: "E27FP1K")
  let r = DisplayResolver.resolve(ddc: [], cg: [a, b])
  check(r.software.count == 2, "serial-0 twins both enroll")
  check(r.software[0].key != r.software[1].key, "serial-0 twins do not share one key")
  check(r.software[0].key == "sw-10635-10049-0", "the first twin keeps the short key")
  check(r.software[1].key == "sw-10635-10049-0-4", "the repeat is disambiguated by unit number")
  check(r.software.map(\.cgID) == [40, 41], "both keep their own CoreGraphics id")
}

// 11. A lone panel is unaffected by the uniqueness pass: no suffix, so its
//     profile survives a replug.
do {
  let solo = CGDisplayCandidate(id: 40, vendor: 10635, model: 10049, serial: 0, unit: 3, name: "E27FP1K")
  let r = DisplayResolver.resolve(ddc: [], cg: [solo])
  check(r.software.first?.key == "sw-10635-10049-0", "a single panel keeps its short key")
}

// 12. The general invariant: resolve() never emits two software displays with
//     the same key, whatever the EDIDs look like. Includes blank EDIDs sharing
//     a name and a unit number, which no other signal can tell apart.
do {
  let candidates = [
    CGDisplayCandidate(id: 50, vendor: 0, model: 0, serial: 0, unit: 1, name: "Panel"),
    CGDisplayCandidate(id: 51, vendor: 0, model: 0, serial: 0, unit: 1, name: "Panel"),
    CGDisplayCandidate(id: 52, vendor: 0, model: 0, serial: 0, unit: 1, name: nil),
    CGDisplayCandidate(id: 53, vendor: 7789, model: 22881, serial: 0, unit: 2, name: "LG"),
    CGDisplayCandidate(id: 54, vendor: 7789, model: 22881, serial: 0, unit: 2, name: "LG"),
    CGDisplayCandidate(id: 55, vendor: 7789, model: 22881, serial: 0, unit: 2, name: "LG"),
    CGDisplayCandidate(id: 56, vendor: 7789, model: 22881, serial: 99, unit: 3, name: "LG"),
  ]
  let r = DisplayResolver.resolve(ddc: [], cg: candidates)
  check(r.software.count == candidates.count, "every unclaimed display enrolls")
  check(Set(r.software.map(\.key)).count == r.software.count, "no two software displays share a key")
  check(Set(r.software.map(\.cgID)) == Set(candidates.map(\.id)), "every display keeps its own id")
}

print(failures == 0 ? "\nAll DisplayResolver checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
