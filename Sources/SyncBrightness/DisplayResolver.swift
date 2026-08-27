import CoreGraphics
import Foundation

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
  /// Apple's EDID vendor number. AirPlay targets and Sidecar iPads report it.
  /// They are real CoreGraphics displays with no DDC channel, so they look
  /// exactly like a DisplayLink monitor to the resolver — but dimming an Apple
  /// TV to match the laptop mid-session is not what anyone wants, so they
  /// enroll switched off.
  static let appleVendorNumber: UInt32 = 0x610

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
    //
    // The key is the display's identity everywhere else in the app (profiles,
    // the disabled/seen sets, the per-monitor slider lookup), so it has to be
    // unique within one scan. Two identical panels on one dock that report a
    // real vendor and model but serial 0 would otherwise share a key, and
    // toggling one would toggle both. Disambiguate the repeats with the
    // CoreGraphics unit number.
    //
    // Residual, stated honestly: with serial 0 there is no stable
    // disambiguator. Which twin keeps the short key and which gets the suffix
    // can swap between sessions, and their calibration profiles swap with them.
    // That is a cosmetic loss on a rare setup, not a stuck screen.
    var usedKeys: Set<String> = []
    var software: [SoftwareDisplay] = []
    for candidate in pool {
      // A single panel keeps its short, replug-stable key; a repeat takes the
      // unit number as its disambiguator.
      let base = softwareKey(for: candidate)
      var key = usedKeys.contains(base) ? "\(base)-\(candidate.unit)" : base
      // Belt and braces: unit numbers are not guaranteed distinct either.
      let disambiguated = key
      var attempt = 2
      while usedKeys.contains(key) {
        key = "\(disambiguated)-\(attempt)"
        attempt += 1
      }
      usedKeys.insert(key)
      software.append(SoftwareDisplay(key: key,
                                      name: candidate.name ?? "External display",
                                      cgID: candidate.id,
                                      prefersDefaultDisabled: candidate.vendor == Self.appleVendorNumber))
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
