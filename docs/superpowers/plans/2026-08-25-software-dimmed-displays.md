# Software-Dimmed Displays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make external displays that have no DDC/CI channel — DisplayLink docks, some
USB-C hubs, certain TVs — follow the built-in display's brightness via the CoreGraphics
gamma table, as first-class monitors with their own calibration curve.

**Architecture:** `ExternalDisplay.service` becomes optional; a display with no
`IOAVService` is permanently in the gamma-follow state the class already models. A new pure
`DisplayResolver` decides which `CGDirectDisplayID` belongs to which DDC display and
declares the residue software-only, so the whole rule is unit-testable without hardware.
`SyncController` gains a software-only branch at each of its three drive points.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit/CoreGraphics/IOKit. No new dependencies.
Tests are framework-free drivers compiled by `./run-tests.sh` with Command Line Tools only.

**Design doc:** `docs/superpowers/specs/2026-08-25-software-dimmed-displays-design.md`

## Global Constraints

- Swift tools version 5.9; platform floor macOS 13 (`Package.swift`). Do not raise either.
- Apple Silicon only. Do not add an Intel DDC path.
- No new package dependencies. Tests must run under `./run-tests.sh` with Command Line
  Tools only — XCTest and swift-testing require full Xcode and are unavailable.
- **All mutable sync state and all DDC/gamma calls happen on `SyncController.queue`.** Cross
  to main only for UI callbacks. Never call `DispatchQueue.main.sync` from that queue —
  `shutdown()` calls `queue.sync` from main and it will deadlock.
- **Be gentle with DDC.** Writes stay single-cycle and low-retry; reconcile reads stay
  infrequent. Do not add DDC traffic.
- Apple's EDID vendor number is `0x610` (1552 decimal).
- The gamma clamp floor is `0.15` (`SyncController.minGammaFactor`).
- Software-only display profile keys are prefixed `sw-` and must never collide with DDC
  keys, which are `MANUFACTURER-ProductName-serial`.

---

### Task 1: Pure display resolver

The claim cascade and identity-key rules, as a pure function over plain values so they can
be tested without a monitor attached. This task adds no behavior to the app — nothing calls
the resolver until Task 2.

**Files:**
- Create: `Sources/SyncBrightness/DisplayResolver.swift`
- Create: `Tests/ResolverChecks/main.swift`
- Modify: `run-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `CGDisplayCandidate`, `DDCCandidate`, `SoftwareDisplay`, `DisplayAssignment`,
  `DisplayResolver.resolve(ddc:cg:)`, `DisplayResolver.softwareKey(for:)`,
  `kAppleVendorNumber`. Task 2 calls `resolve`. Field names are load-bearing — later tasks
  reference `SoftwareDisplay.key`, `.name`, `.cgID`, `.prefersDefaultDisabled` and
  `DisplayAssignment.ddc`, `.software` exactly as spelled here.

- [ ] **Step 1: Write the failing test**

Create `Tests/ResolverChecks/main.swift`:

```swift
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

print(failures == 0 ? "\nAll DisplayResolver checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Register the suite in the test runner**

In `run-tests.sh`, add this block immediately after the existing `run_check curve-checks`
block and before `run_check hotkey-checks`:

```bash
run_check resolver-checks \
  -framework CoreGraphics \
  Sources/SyncBrightness/DisplayResolver.swift \
  Tests/ResolverChecks/main.swift
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./run-tests.sh`
Expected: FAIL. The `resolver-checks` block errors with
`error: no such file or directory: 'Sources/SyncBrightness/DisplayResolver.swift'`, and the
script exits non-zero. `curve-checks` and `hotkey-checks` still pass.

- [ ] **Step 4: Write the implementation**

Create `Sources/SyncBrightness/DisplayResolver.swift`:

```swift
import CoreGraphics
import Foundation

/// Apple's EDID vendor number. AirPlay targets and Sidecar iPads report it. They
/// are real CoreGraphics displays with no DDC channel, so they look exactly like
/// a DisplayLink monitor to the resolver — but dimming an Apple TV to match the
/// laptop mid-session is not what anyone wants, so they enroll switched off.
let kAppleVendorNumber: UInt32 = 0x610

/// A CoreGraphics display reduced to plain values, so the claim cascade can be
/// tested without hardware attached.
struct CGDisplayCandidate: Equatable {
  let id: CGDirectDisplayID
  let vendor: UInt32
  let model: UInt32
  let serial: UInt32
  let unit: UInt32
  /// From the screen-name cache. Nil when the cache is cold.
  let name: String?
}

/// A display found over DDC/CI, waiting to be matched to a CoreGraphics display.
struct DDCCandidate: Equatable {
  /// EDID serial number. 0 means the monitor does not report one.
  let serial: Int64
  /// EDID product id. 0 means the monitor does not report one.
  let model: UInt32
}

/// A display with no DDC channel, which can only be dimmed via the gamma table.
struct SoftwareDisplay: Equatable {
  let key: String
  let name: String
  let cgID: CGDirectDisplayID
  let prefersDefaultDisabled: Bool
}

struct DisplayAssignment: Equatable {
  /// One entry per DDC candidate, in the order they were passed in. Nil means no
  /// CoreGraphics display could be matched to it.
  var ddc: [CGDirectDisplayID?]
  var software: [SoftwareDisplay]
}

/// Decides which CoreGraphics display belongs to which DDC monitor, and declares
/// everything left over software-only.
///
/// There is no positive way to identify a virtual display from CoreGraphics
/// alone, so this is a cascade of decreasingly certain signals. The residue —
/// step 4 — is the part that matters: those displays are currently discarded
/// rather than driven, which is why a DisplayLink monitor never syncs.
enum DisplayResolver {
  static func resolve(ddc: [DDCCandidate], cg: [CGDisplayCandidate]) -> DisplayAssignment {
    var pool = cg
    var assigned = [CGDirectDisplayID?](repeating: nil, count: ddc.count)

    func claim(_ poolIndex: Int, for ddcIndex: Int) {
      assigned[ddcIndex] = pool[poolIndex].id
      pool.remove(at: poolIndex)
    }

    // 1. EDID serial — the strongest signal, and the only one that survives two
    //    identical monitors.
    for (i, candidate) in ddc.enumerated() where candidate.serial != 0 {
      if let p = pool.firstIndex(where: { Int64($0.serial) == candidate.serial }) {
        claim(p, for: i)
      }
    }

    // 2. Product id, but only when it is unambiguous. Two matches is not a
    //    tiebreak, so leave those to connection order rather than guessing.
    for (i, candidate) in ddc.enumerated() where assigned[i] == nil && candidate.model != 0 {
      let matches = pool.indices.filter { pool[$0].model == candidate.model }
      if matches.count == 1 { claim(matches[0], for: i) }
    }

    // 3. Connection order for whatever is still unresolved.
    for i in ddc.indices where assigned[i] == nil {
      if pool.isEmpty { break }
      claim(0, for: i)
    }

    // 4. Anything no DDC monitor claimed has no DDC channel.
    let software = pool.map {
      SoftwareDisplay(key: softwareKey(for: $0),
                      name: $0.name ?? "External display",
                      cgID: $0.id,
                      prefersDefaultDisabled: $0.vendor == kAppleVendorNumber)
    }
    return DisplayAssignment(ddc: assigned, software: software)
  }

  /// Stable profile key for a software-only display. The `sw-` prefix cannot
  /// collide with a DDC key (`MANUFACTURER-ProductName-serial`), and the EDID
  /// numbers survive a replug where `CGDirectDisplayID` does not.
  static func softwareKey(for display: CGDisplayCandidate) -> String {
    guard display.vendor == 0, display.model == 0, display.serial == 0 else {
      return "sw-\(display.vendor)-\(display.model)-\(display.serial)"
    }
    // No EDID identity at all. Fall back to something that at least differs
    // between two such panels, so they don't share one calibration profile.
    let name = (display.name ?? "unknown").replacingOccurrences(of: " ", with: "-")
    return "sw-0-0-0-\(name)-\(display.unit)"
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./run-tests.sh`
Expected: PASS. `resolver-checks` prints nine groups of `✓` lines followed by
`All DisplayResolver checks passed`, and the script exits 0.

- [ ] **Step 6: Verify the app still builds**

Run: `swift build -c release 2>&1 | tail -5`
Expected: `Build complete!` — `DisplayResolver.swift` joins the target but nothing calls it
yet.

- [ ] **Step 7: Commit**

```bash
git add Sources/SyncBrightness/DisplayResolver.swift Tests/ResolverChecks/main.swift run-tests.sh
git commit -m "feat: pure display resolver for claiming CoreGraphics displays"
```

---

### Task 2: Enumerate software-only displays

Wire the resolver into `DDC.externalDisplays()` so displays with no `IOAVService` are
returned alongside DDC ones.

**Files:**
- Modify: `Sources/SyncBrightness/DDC.swift`

**Interfaces:**
- Consumes: `DisplayResolver.resolve(ddc:cg:)`, `CGDisplayCandidate`, `DDCCandidate` from
  Task 1.
- Produces: `ExternalDisplay.service: IOAVService?`, `ExternalDisplay.isSoftwareOnly`,
  `ExternalDisplay.productID`, `ExternalDisplay.prefersDefaultDisabled`, and
  `DDC.externalDisplays(names:)` taking `[CGDirectDisplayID: String]`. Tasks 3–7 depend on
  these exact names.

- [ ] **Step 1: Make `service` optional and add the new stored properties**

In `Sources/SyncBrightness/DDC.swift`, change the `ExternalDisplay` declarations. Replace:

```swift
final class ExternalDisplay {
  let service: IOAVService
```

with:

```swift
final class ExternalDisplay {
  /// Nil when the display has no DDC/CI channel (DisplayLink, some hubs, some
  /// TVs). Such a display can still be dimmed via the gamma table.
  let service: IOAVService?
  /// A display with no DDC channel is permanently in the gamma-follow state that
  /// this class already models — there is no backlight to talk to.
  var isSoftwareOnly: Bool { service == nil }
```

Then replace the `init`:

```swift
  init(service: IOAVService, id: String, name: String, serialNumber: Int64) {
    self.service = service
    self.id = id
    self.name = name
    self.serialNumber = serialNumber
  }
```

with:

```swift
  /// EDID product id, used to match this monitor to a CoreGraphics display when
  /// the serial number is unreported. 0 means the monitor does not report one.
  let productID: UInt32
  /// Set for software-only displays that should not start dimming on first sight
  /// (AirPlay targets, Sidecar iPads). Consumed by AppDelegate, not here.
  let prefersDefaultDisabled: Bool

  init(service: IOAVService?, id: String, name: String, serialNumber: Int64,
       productID: UInt32 = 0, cgDisplayID: CGDirectDisplayID? = nil,
       prefersDefaultDisabled: Bool = false) {
    self.service = service
    self.id = id
    self.name = name
    self.serialNumber = serialNumber
    self.productID = productID
    self.cgDisplayID = cgDisplayID
    self.prefersDefaultDisabled = prefersDefaultDisabled
  }
```

- [ ] **Step 2: Report a sensible level for a software-only display**

Still in `ExternalDisplay`, replace:

```swift
  var currentFraction: Double { followsViaGamma ? gammaFollowLevel : (lastSetFraction ?? 0) }
```

with:

```swift
  var currentFraction: Double {
    if followsViaGamma { return gammaFollowLevel }
    // A software-only display we aren't dimming is at the panel's own setting,
    // which is this app's 100% — not 0, which would read as "off" in the UI.
    if isSoftwareOnly { return 1.0 }
    return lastSetFraction ?? 0
  }
```

- [ ] **Step 3: Guard the DDC calls against a nil service**

Replace:

```swift
  func refreshMaxBrightness() {
    if let result = DDC.read(service: service, command: kVCPBrightness, retries: 4), result.max > 0 {
```

with:

```swift
  func refreshMaxBrightness() {
    guard let service else { return } // no bus to probe
    if let result = DDC.read(service: service, command: kVCPBrightness, retries: 4), result.max > 0 {
```

Replace:

```swift
  private func write(fraction: Double, retries: Int) -> Bool {
    let value = UInt16((fraction * Double(maxBrightness)).rounded())
    return DDC.write(service: service, command: kVCPBrightness, value: value, retries: retries)
  }
```

with:

```swift
  private func write(fraction: Double, retries: Int) -> Bool {
    guard let service else { return false } // no DDC channel — the caller dims via gamma
    let value = UInt16((fraction * Double(maxBrightness)).rounded())
    return DDC.write(service: service, command: kVCPBrightness, value: value, retries: retries)
  }
```

- [ ] **Step 4: Read the product id out of the IORegistry**

Replace the signature and body of `identity(of:)`. Change:

```swift
  private static func identity(of entry: io_service_t) -> (id: String, name: String, serial: Int64)? {
```

to:

```swift
  private static func identity(of entry: io_service_t) -> (id: String, name: String, serial: Int64, productID: UInt32)? {
```

Inside it, after the `let serialNumber` line, add:

```swift
    let productID = UInt32((product["ProductID"] as? Int) ?? 0)
```

and change the final `return` from:

```swift
    return (id, name, serialNumber)
```

to:

```swift
    return (id, name, serialNumber, productID)
```

- [ ] **Step 5: Replace enumeration and display-id resolution**

In `externalDisplays()`, change the signature:

```swift
  static func externalDisplays() -> [ExternalDisplay] {
```

to:

```swift
  /// Every external display we can drive: over DDC/CI where the monitor speaks
  /// it, and via the gamma table where it does not. `names` is the screen-name
  /// cache from AppDelegate — `NSScreen` is main-thread-only, and this runs on
  /// the sync queue.
  static func externalDisplays(names: [CGDirectDisplayID: String] = [:]) -> [ExternalDisplay] {
```

Change the `lastIdentity` declaration from:

```swift
    var lastIdentity = (id: "external", name: "External display", serial: Int64(0))
```

to:

```swift
    var lastIdentity = (id: "external", name: "External display", serial: Int64(0), productID: UInt32(0))
```

Change the `displays.append` line from:

```swift
          displays.append(ExternalDisplay(service: service, id: lastIdentity.id, name: lastIdentity.name, serialNumber: lastIdentity.serial))
```

to:

```swift
          displays.append(ExternalDisplay(service: service, id: lastIdentity.id, name: lastIdentity.name,
                                          serialNumber: lastIdentity.serial, productID: lastIdentity.productID))
```

Change the tail of the function from:

```swift
    Self.resolveDisplayIDs(displays)
    return displays
  }
```

to:

```swift
    return displays + Self.attachDisplayIDs(to: displays, names: names)
  }
```

Then replace the whole of `resolveDisplayIDs(_:)` — from its doc comment through its closing
brace — with:

```swift
  /// Assign a CoreGraphics display id to each DDC display, and build an
  /// `ExternalDisplay` for every display no DDC monitor claimed. The rule itself
  /// lives in `DisplayResolver` so it can be unit-tested; this is just the
  /// CoreGraphics plumbing around it.
  static func attachDisplayIDs(to ddcDisplays: [ExternalDisplay],
                               names: [CGDirectDisplayID: String]) -> [ExternalDisplay] {
    let assignment = DisplayResolver.resolve(
      ddc: ddcDisplays.map { DDCCandidate(serial: $0.serialNumber, model: $0.productID) },
      cg: cgCandidates(names: names))

    for (i, display) in ddcDisplays.enumerated() {
      display.cgDisplayID = assignment.ddc[i]
    }
    return assignment.software.map {
      ExternalDisplay(service: nil, id: $0.key, name: $0.name, serialNumber: 0,
                      cgDisplayID: $0.cgID, prefersDefaultDisabled: $0.prefersDefaultDisabled)
    }
  }

  private static func cgCandidates(names: [CGDirectDisplayID: String]) -> [CGDisplayCandidate] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.filter { CGDisplayIsBuiltin($0) == 0 }.map {
      CGDisplayCandidate(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                         serial: CGDisplaySerialNumber($0), unit: CGDisplayUnitNumber($0), name: names[$0])
    }
  }
```

- [ ] **Step 6: Fix the debug dump's use of `identity`**

`debugServiceDump()` reads `identity(of: entry)?.name`, which still compiles against the
widened tuple. Verify no other call site of `identity(of:)` destructures it positionally.

Run: `grep -n "identity(of:" Sources/SyncBrightness/DDC.swift`
Expected: exactly two call sites — one in `externalDisplays()` assigning to `lastIdentity`,
one in `debugServiceDump()` reading `?.name`.

- [ ] **Step 7: Build**

Run: `swift build -c release 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 8: Verify enumeration on real hardware**

Run: `SYNCBRIGHTNESS_DIAG=1 ./.build/release/SyncBrightness 2>&1 | head -20`
Expected: still reports `External displays over DDC/CI: 0` (this counter is not updated
until Task 7) and does not crash. The behavioral proof comes in Task 3.

- [ ] **Step 9: Run the unit checks**

Run: `./run-tests.sh`
Expected: PASS, all three suites.

- [ ] **Step 10: Commit**

```bash
git add Sources/SyncBrightness/DDC.swift
git commit -m "feat: enumerate displays that have no DDC channel"
```

---

### Task 3: Drive software-only displays

Make `SyncController` actually dim them, through their calibration curve.

**Files:**
- Modify: `Sources/SyncBrightness/SyncController.swift`

**Interfaces:**
- Consumes: `ExternalDisplay.isSoftwareOnly`, `.prefersDefaultDisabled` from Task 2.
- Produces: `MonitorState.softwareDimmed`, `MonitorState.prefersDefaultDisabled`,
  `SyncController.setDisplayNames(_:)`. Tasks 4–6 depend on these.

- [ ] **Step 1: Add the new fields to `MonitorState`**

In `Sources/SyncBrightness/DDC.swift`, replace:

```swift
struct MonitorState: Equatable {
  let id: String
  let name: String
  var enabled: Bool
  var healthy: Bool
  var brightness: Double // current external fraction 0...1
}
```

with:

```swift
struct MonitorState: Equatable {
  let id: String
  let name: String
  var enabled: Bool
  var healthy: Bool
  var brightness: Double // current external fraction 0...1
  /// Dimmed via the gamma table because the display has no DDC channel.
  var softwareDimmed = false
  /// Should enroll switched off the first time it is seen. See DisplayResolver.
  var prefersDefaultDisabled = false
}
```

- [ ] **Step 2: Branch `setLevel` for software-only displays**

In `Sources/SyncBrightness/SyncController.swift`, replace the body of `setLevel` — from
`let belowFloor` down to the closing brace — with:

```swift
    let minGamma = allowBlackout ? 0.0 : minGammaFactor

    if display.isSoftwareOnly {
      // No DDC channel: the curve's output *is* the luminance scale, and gamma
      // is the only lever. The blackout clamp is kept even when "allow blackout"
      // is on — there is no backlight to fall back on here, so a zero factor
      // leaves a screen too dark to read the checkbox that would undo it.
      guard display.cgDisplayID != nil else { display.clearGammaFollow(); return }
      let level = max(minGammaFactor, ddcFraction)
      gamma.set(display.cgDisplayID, factor: level)
      display.markGammaFollow(level: level)
      return
    }

    let belowFloor = subFloorDimming && floor > 0 && dimInput < floor
    let wroteOK = display.setBrightness(fraction: belowFloor ? 0 : ddcFraction, ramp: ramp)

    if !wroteOK {
      // DDC not accepted on this display — follow the built-in via gamma. This is
      // the only way to dim a monitor that doesn't speak DDC, so trade backlight
      // control for a software luminance scale. Only possible (and only reported
      // as working) when we resolved a CoreGraphics display id to drive.
      if display.cgDisplayID != nil {
        // Use the curve's output, not the raw built-in level: a monitor that
        // falls back to gamma should still honour its calibration.
        let level = max(minGamma, ddcFraction)
        gamma.set(display.cgDisplayID, factor: level)
        display.markGammaFollow(level: level)
      } else {
        display.clearGammaFollow() // no DDC and no gamma path — genuinely unreachable
      }
      return
    }
    display.clearGammaFollow()
    if belowFloor {
      // Below the floor, hold DDC at minimum and dim via gamma. Normally clamped
      // to a small visible floor; full blackout removes the clamp so it reaches 0.
      gamma.set(display.cgDisplayID, factor: max(minGamma, dimInput / floor))
    } else {
      gamma.set(display.cgDisplayID, factor: 1)
    }
  }
```

- [ ] **Step 3: Make calibration work on a software-only display**

In `tick()`, replace:

```swift
      for display in externals where calibrationTargetID == nil || display.id == calibrationTargetID {
        gamma.set(display.cgDisplayID, factor: 1) // pure DDC while calibrating
        display.setBrightness(fraction: manualExternal)
      }
```

with:

```swift
      for display in externals where calibrationTargetID == nil || display.id == calibrationTargetID {
        if display.isSoftwareOnly {
          // Pinning gamma to 1 and writing DDC would move the slider and change
          // nothing on screen, making the curve uncalibratable. Drive gamma.
          let level = max(minGammaFactor, manualExternal)
          gamma.set(display.cgDisplayID, factor: level)
          display.markGammaFollow(level: level)
        } else {
          gamma.set(display.cgDisplayID, factor: 1) // pure DDC while calibrating
          display.setBrightness(fraction: manualExternal)
        }
      }
```

- [ ] **Step 4: Keep reconcile off the software-only displays**

Replace:

```swift
    for display in externals where !disabledIDs.contains(display.id) && !display.followsViaGamma && display.readResponsive {
      guard let result = DDC.read(service: display.service, command: kVCPBrightness), result.max > 0 else { continue }
```

with:

```swift
    for display in externals where !disabledIDs.contains(display.id) && !display.isSoftwareOnly
      && !display.followsViaGamma && display.readResponsive {
      guard let service = display.service,
            let result = DDC.read(service: service, command: kVCPBrightness), result.max > 0 else { continue }
```

- [ ] **Step 5: Report the new state to the UI**

Replace `reportMonitors()` with:

```swift
  private func reportMonitors() {
    let states = externals.map {
      MonitorState(id: $0.id, name: $0.name,
                   enabled: !disabledIDs.contains($0.id),
                   // A software-only display is healthy when we have a display to
                   // drive; a DDC one when writes land or gamma is tracking.
                   healthy: $0.isSoftwareOnly ? ($0.cgDisplayID != nil) : ($0.lastWriteOK || $0.followsViaGamma),
                   brightness: $0.currentFraction,
                   softwareDimmed: $0.isSoftwareOnly,
                   prefersDefaultDisabled: $0.prefersDefaultDisabled)
    }
    DispatchQueue.main.async { self.onMonitors?(states) }
  }
```

- [ ] **Step 6: Accept the screen-name cache and pass it to enumeration**

Add this stored property next to the other private state (after `private var allowBlackout = false`):

```swift
  // Screen names come from AppKit, which is main-thread-only, so AppDelegate
  // collects them and hands them over rather than us reaching for NSScreen here.
  private var displayNames: [CGDirectDisplayID: String] = [:]
```

Add this method in the `// MARK: - Configuration` section, after `setAllowBlackout`:

```swift
  func setDisplayNames(_ names: [CGDirectDisplayID: String]) {
    queue.async {
      guard self.displayNames != names else { return }
      self.displayNames = names
      self.rescanDisplays()
    }
  }
```

In `rescanDisplays()`, replace:

```swift
    externals = DDC.externalDisplays()
```

with:

```swift
    externals = DDC.externalDisplays(names: displayNames)
```

- [ ] **Step 7: Build**

Run: `swift build -c release 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 8: Verify on real hardware**

Run: `./build.sh && open "build/Monitor Brightness Sync.app"`

Then, with the DisplayLink monitor attached: press the brightness-down key on the Mac.
Expected: the external monitor dims along with the built-in. Press brightness-up: it
brightens back. Open the control window's Displays tab: the monitor is listed with a
working enable switch and slider.

If the monitor does not dim, do not proceed — check `SYNCBRIGHTNESS_DIAG=1` output and
whether `attachDisplayIDs` produced a software display.

- [ ] **Step 9: Run the unit checks**

Run: `./run-tests.sh`
Expected: PASS, all three suites.

- [ ] **Step 10: Commit**

```bash
git add Sources/SyncBrightness/SyncController.swift Sources/SyncBrightness/DDC.swift
git commit -m "feat: sync non-DDC displays via gamma, through their calibration curve"
```

---

### Task 4: Screen-name cache

Without this, the DisplayLink monitor is labelled "External display" instead of its real
name, because the IORegistry path has no product name for it.

**Files:**
- Modify: `Sources/SyncBrightness/AppDelegate.swift`

**Interfaces:**
- Consumes: `SyncController.setDisplayNames(_:)` from Task 3.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Add the cache and its refresh**

In `Sources/SyncBrightness/AppDelegate.swift`, add near the other private state (after
`private var monitors: [MonitorState] = []`):

```swift
  // NSScreen is main-thread-only and SyncController runs its scans on a private
  // queue, so names are collected here and handed over. Never reach for NSScreen
  // from the sync queue — shutdown() does queue.sync from main and it deadlocks.
  private var displayNames: [CGDirectDisplayID: String] = [:]
```

Add these methods next to the other private helpers:

```swift
  /// Collect display names on the main thread and hand them to the controller.
  private func refreshDisplayNames() {
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      names[CGDirectDisplayID(truncating: number)] = screen.localizedName
    }
    guard names != displayNames else { return }
    displayNames = names
    sync.setDisplayNames(names)
  }

  @objc private func screenParametersChanged() {
    refreshDisplayNames()
  }
```

- [ ] **Step 2: Populate before the first scan, and observe changes**

In `applicationDidFinishLaunching`, find the block that ends with `sync.setDisabled(disabledIDs)`.
Immediately after that line, add:

```swift
    // Populate the name cache before the first scan so the first enumeration
    // isn't cold; the notification keeps it current afterwards.
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    refreshDisplayNames()
```

Verify this lands before the call to `sync.start()`.

Run: `grep -n "refreshDisplayNames()\|sync.start()" Sources/SyncBrightness/AppDelegate.swift`
Expected: the `refreshDisplayNames()` line number is lower than the `sync.start()` line number.

- [ ] **Step 3: Build**

Run: `swift build -c release 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 4: Verify the name on real hardware**

Run: `./build.sh && open "build/Monitor Brightness Sync.app"`
Open the control window's Displays tab.
Expected: the monitor is listed by its real name — on the reference machine, `E27FP1K`, not
`External display`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SyncBrightness/AppDelegate.swift
git commit -m "feat: cache screen names on main for software-only display labels"
```

---

### Task 5: First-sight enrollment defaults

A software-only display appears the instant an AirPlay session starts. Without this, an
Apple TV would be enrolled enabled and immediately dimmed to match the laptop.

**Files:**
- Modify: `Sources/SyncBrightness/AppDelegate.swift`

**Interfaces:**
- Consumes: `MonitorState.prefersDefaultDisabled` from Task 3.
- Produces: the `"seenMonitors"` `UserDefaults` key.

- [ ] **Step 1: Add the seen-set storage**

In `Sources/SyncBrightness/AppDelegate.swift`, next to `private let disabledKey = "disabledMonitors"`, add:

```swift
  // `disabledIDs` records displays the user switched off. It cannot tell "never
  // seen" from "seen and left on", so a default-disabled rule needs its own set —
  // otherwise every relaunch would re-disable a display the user turned on.
  private let seenKey = "seenMonitors"
  private var seenIDs: Set<String> = []
```

- [ ] **Step 2: Load it at launch**

Immediately after the existing line:

```swift
    disabledIDs = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
```

add:

```swift
    seenIDs = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
```

- [ ] **Step 3: Apply the default when a display first appears**

Add this method next to the other private helpers:

```swift
  /// Give a never-before-seen display its default. Everything enrolls syncing
  /// except software-dimmed Apple-vendor displays — AirPlay targets and Sidecar
  /// iPads, which should not start dimming the moment a session begins. They are
  /// still listed, so turning one on is a single switch.
  private func applyFirstSightDefaults(_ monitors: [MonitorState]) {
    var newlySeen = false
    var disabledChanged = false
    for monitor in monitors where !seenIDs.contains(monitor.id) {
      seenIDs.insert(monitor.id)
      newlySeen = true
      if monitor.prefersDefaultDisabled {
        disabledIDs.insert(monitor.id)
        disabledChanged = true
      }
    }
    guard newlySeen else { return }
    UserDefaults.standard.set(Array(seenIDs), forKey: seenKey)
    guard disabledChanged else { return }
    UserDefaults.standard.set(Array(disabledIDs), forKey: disabledKey)
    // This re-enters via onMonitors, but every display is in seenIDs by now, so
    // the next pass returns at the `guard newlySeen` above.
    sync.setDisabled(disabledIDs)
  }
```

- [ ] **Step 4: Call it from the monitors callback**

In `applicationDidFinishLaunching`, replace:

```swift
    sync.onMonitors = { [weak self] monitors in
      guard let self else { return }
      self.monitors = monitors
```

with:

```swift
    sync.onMonitors = { [weak self] monitors in
      guard let self else { return }
      self.applyFirstSightDefaults(monitors)
      self.monitors = monitors
```

- [ ] **Step 5: Build**

Run: `swift build -c release 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 6: Verify persistence on real hardware**

```bash
./build.sh && open "build/Monitor Brightness Sync.app"
```

In the control window, switch the DisplayLink monitor **off**. Quit the app and relaunch it.
Expected: the monitor is still switched off — the seen-set did not reset the user's choice.
Switch it back on, quit, relaunch: still on.

Then confirm the default was recorded:

Run: `defaults read com.rick.syncbrightness seenMonitors`
Expected: an array containing the `sw-…` key for the display.

- [ ] **Step 7: Commit**

```bash
git add Sources/SyncBrightness/AppDelegate.swift
git commit -m "feat: default-disable AirPlay and Sidecar displays on first sight"
```

---

### Task 6: Mark software-dimmed displays in the UI

The monitor's name is rendered in three places from two files. Give `MonitorState` one
title so they cannot drift apart.

**Files:**
- Modify: `Sources/SyncBrightness/DDC.swift`
- Modify: `Sources/SyncBrightness/ControlWindowController.swift:138`, `:317`
- Modify: `Sources/SyncBrightness/AppDelegate.swift:411`

**Interfaces:**
- Consumes: `MonitorState.softwareDimmed`, `.healthy`, `.name` from Task 3.
- Produces: `MonitorState.displayTitle`.

- [ ] **Step 1: Add the shared title**

In `Sources/SyncBrightness/DDC.swift`, inside `struct MonitorState`, after the stored
properties, add:

```swift
  /// The one place a monitor's row title is composed. Used by the menu and the
  /// control window so they can never disagree.
  var displayTitle: String {
    let base = softwareDimmed ? "\(name) (software dimming)" : name
    return healthy ? base : "⚠ \(base)"
  }
```

- [ ] **Step 2: Use it in the control window**

In `Sources/SyncBrightness/ControlWindowController.swift`, in `updateMonitors`, replace:

```swift
        rowLabels[i].stringValue = m.healthy ? m.name : "⚠ \(m.name)"
```

with:

```swift
        rowLabels[i].stringValue = m.displayTitle
```

In `buildMonitorsCard`, replace:

```swift
      let label = NSTextField(labelWithString: monitor.healthy ? monitor.name : "⚠ \(monitor.name)")
```

with:

```swift
      let label = NSTextField(labelWithString: monitor.displayTitle)
```

- [ ] **Step 3: Use it in the menu**

In `Sources/SyncBrightness/AppDelegate.swift`, replace:

```swift
      let check = NSMenuItem(title: monitor.healthy ? monitor.name : "⚠ \(monitor.name)",
```

with:

```swift
      let check = NSMenuItem(title: monitor.displayTitle,
```

- [ ] **Step 4: Explain software dimming in the menu tooltip**

Still in the same menu-building loop, replace this exact statement:

```swift
      check.toolTip = monitor.healthy
        ? "Include \(monitor.name) in brightness sync."
        : "\(monitor.name) isn't responding to DDC — check that DDC/CI is enabled in its menu."
```

with:

```swift
      check.toolTip = !monitor.healthy
        ? "\(monitor.name) isn't responding to DDC — check that DDC/CI is enabled in its menu."
        : monitor.softwareDimmed
          ? "Include \(monitor.name) in brightness sync. It has no DDC channel, so it's dimmed in software: it follows the built-in downward from the panel's own brightness setting, and can't be brightened past it."
          : "Include \(monitor.name) in brightness sync."
```

Both existing strings are preserved verbatim — only the software-dimming case is new. Do
not reword the other two.

- [ ] **Step 5: Confirm no name rendering was missed**

Run: `grep -n '⚠ \\(m' Sources/SyncBrightness/*.swift`
Expected: no output — every site now goes through `displayTitle`.

- [ ] **Step 6: Build and look at it**

Run: `./build.sh && open "build/Monitor Brightness Sync.app"`
Expected: the Displays tab and the Monitors submenu both read
`E27FP1K (software dimming)`, and the submenu tooltip explains the downward-only limit.

- [ ] **Step 7: Commit**

```bash
git add Sources/SyncBrightness/DDC.swift Sources/SyncBrightness/ControlWindowController.swift Sources/SyncBrightness/AppDelegate.swift
git commit -m "feat: mark software-dimmed monitors in the menu and control window"
```

---

### Task 7: Diagnostics and documentation

`SYNCBRIGHTNESS_DIAG=1` currently reports `External displays over DDC/CI: 0` on the affected
machine and says nothing about the display that is actually there — the exact output that
made this bug hard to see. The README also claims behaviour that did not exist.

**Files:**
- Modify: `Sources/SyncBrightness/Diagnostics.swift`
- Modify: `Sources/SyncBrightness/main.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ExternalDisplay.isSoftwareOnly`, `DDC.externalDisplays(names:)` from Task 2.
- Produces: nothing.

- [ ] **Step 1: Let diagnostics use AppKit**

`Diagnostics.run` is called before `NSApplication.shared` exists, and `NSScreen.screens`
needs AppKit initialised. In `Sources/SyncBrightness/main.swift`, move the diagnostics block
below the app creation. Replace the whole file with:

```swift
import Cocoa

let app = NSApplication.shared

if let diag = ProcessInfo.processInfo.environment["SYNCBRIGHTNESS_DIAG"], !diag.isEmpty {
  Diagnostics.run(writeProbe: diag == "write") // =write also exercises a DDC write
  exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar agent, no Dock icon
app.run()
```

- [ ] **Step 2: Report software-only displays**

In `Sources/SyncBrightness/Diagnostics.swift`, change the import block from:

```swift
import CoreGraphics
import Foundation
```

to:

```swift
import AppKit
import CoreGraphics
import Foundation
```

Replace:

```swift
    let externals = DDC.externalDisplays()
    out += "External displays over DDC/CI: \(externals.count)\n"
    for (i, display) in externals.enumerated() {
```

with:

```swift
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      names[CGDirectDisplayID(truncating: number)] = screen.localizedName
    }

    let all = DDC.externalDisplays(names: names)
    let externals = all.filter { !$0.isSoftwareOnly }
    let software = all.filter { $0.isSoftwareOnly }

    out += "External displays over DDC/CI: \(externals.count)\n"
    for (i, display) in externals.enumerated() {
```

Then, immediately after the `for (i, display) in externals.enumerated() { … }` loop closes
and before the `out += "\nIORegistry display services:\n"` line, add:

```swift
    out += "Software-dimmed displays (no DDC channel): \(software.count)\n"
    for (i, display) in software.enumerated() {
      let cg = display.cgDisplayID.map(String.init) ?? "unresolved"
      out += "  [\(i)] \(display.name)  key=\(display.id)  cgDisplayID=\(cg)"
      out += display.prefersDefaultDisabled ? "  (enrolls disabled: Apple vendor)\n" : "\n"
    }
```

- [ ] **Step 3: Build and run the probe**

Run: `swift build -c release && SYNCBRIGHTNESS_DIAG=1 ./.build/release/SyncBrightness 2>&1 | head -20`
Expected, on the reference machine:

```
External displays over DDC/CI: 0
Software-dimmed displays (no DDC channel): 1
  [0] E27FP1K  key=sw-10635-10049-244  cgDisplayID=4
```

- [ ] **Step 4: Correct the README**

In `README.md`, replace the feature bullet:

```markdown
- **Software-gamma fallback** — monitors that don't speak DDC (DisplayLink, some hubs, certain TVs) still follow the built-in via the gamma table.
```

with:

```markdown
- **Software dimming for non-DDC monitors** — displays with no DDC/CI channel (DisplayLink docks, some hubs, certain TVs) follow the built-in via the gamma table, with their own calibration curve. Software dimming only goes *down* from the panel's own brightness setting, so set the monitor's own buttons to maximum and the app's 100% becomes that. AirPlay and Sidecar displays are detected too, but enroll switched off so a session doesn't start dimming a TV.
```

In the **Caveats** section, add these two bullets after the existing "Software dimming and
Night Shift" bullet:

```markdown
- **Software dimming can't brighten.** With no DDC channel there's no backlight to command — the gamma table only scales luminance downward. "Allow dimming all the way to black" is also ignored for these displays: there's no backlight to fall back on, so removing the clamp would leave a screen too dark to read the control that undoes it.
- **DisplayLink still needs its driver.** This app controls brightness on a DisplayLink monitor; it does not replace DisplayLink Manager, which is what puts pixels on the screen. There is no way around that on macOS.
```

In the **Repo layout** section, add this line immediately after the `BrightnessCurve.swift` line:

```markdown
    DisplayResolver.swift     Claims CoreGraphics displays for DDC monitors; the rest are software-dimmed (pure, tested)
```

In the same section, add this line after the `Tests/HotKeyChecks/` line:

```markdown
  ResolverChecks/             DisplayResolver claim-cascade and identity-key checks
```

- [ ] **Step 5: Run everything**

Run: `./run-tests.sh && swift build -c release 2>&1 | tail -3`
Expected: all three suites pass, then `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/SyncBrightness/Diagnostics.swift Sources/SyncBrightness/main.swift README.md
git commit -m "feat: report software-dimmed displays in diagnostics; correct README claims"
```

---

## Final verification

- [ ] `./run-tests.sh` — three suites, all pass
- [ ] `./build.sh` — builds and signs
- [ ] `SYNCBRIGHTNESS_DIAG=1 ./.build/release/SyncBrightness` lists the DisplayLink display
      under "Software-dimmed displays"
- [ ] Brightness keys move the DisplayLink monitor with the built-in
- [ ] The monitor's enable switch and slider work in the Displays tab
- [ ] Calibration window: dragging the slider visibly changes the DisplayLink monitor
- [ ] Quitting the app restores the display to full brightness
- [ ] `killall -9 "Monitor Brightness Sync"` while dimmed, then relaunch: brightness recovers
- [ ] The user's enable/disable choice survives a relaunch
