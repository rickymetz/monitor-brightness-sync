import Foundation

/// Helpers for the stable per-monitor identity string that keys calibration
/// profiles, the disabled-monitor set, and every per-monitor control.
enum DisplayIdentity {
  /// Make a list of display ids unique, preserving order.
  ///
  /// An id is built from the EDID's manufacturer + product + serial, so two
  /// monitors of the same model that report no serial produce the *same* string.
  /// Since that string is the handle every per-monitor feature uses, a collision
  /// makes the pair behave as one display: enabling one disables both, the
  /// brightness slider only ever reaches the first, and they share a calibration
  /// profile. Suffixing the later duplicates keeps each monitor's settings its
  /// own. The first occurrence is left untouched so profiles saved before this
  /// existed still load for single-monitor setups.
  static func uniqued(_ ids: [String]) -> [String] {
    var used = Set<String>()
    var result: [String] = []
    result.reserveCapacity(ids.count)
    for id in ids {
      var candidate = id
      var suffix = 2
      while used.contains(candidate) {
        candidate = "\(id)#\(suffix)"
        suffix += 1
      }
      used.insert(candidate)
      result.append(candidate)
    }
    return result
  }

  /// Number repeated display names, preserving order — two monitors of the same
  /// model otherwise show up as two identical, indistinguishable rows.
  /// Names that occur once are left alone.
  static func disambiguated(names: [String]) -> [String] {
    var totals: [String: Int] = [:]
    for name in names { totals[name, default: 0] += 1 }
    var seen: [String: Int] = [:]
    return names.map { name in
      guard totals[name, default: 0] > 1 else { return name }
      let index = seen[name, default: 0] + 1
      seen[name] = index
      return "\(name) (\(index))"
    }
  }
}
