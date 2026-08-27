import Foundation

/// The two facts first-sight enrollment needs about a display. Kept separate
/// from `MonitorState` so the decision below can be tested without dragging in
/// IOKit.
struct FirstSightMonitor: Equatable {
  let id: String
  let prefersDefaultDisabled: Bool
}

/// Decides what a never-before-seen display's defaults are.
///
/// `disabled` records displays the user switched off, and cannot tell "never
/// seen" from "seen and left on" — hence the separate `seen` set, without which
/// every relaunch would re-disable a display the user had turned on.
enum FirstSight {
  struct Outcome: Equatable {
    var seen: Set<String>
    var disabled: Set<String>
    /// A display was seen for the first time, so `seen` needs persisting.
    var newlySeen: Bool
    /// A first-sight default switched a display off, so `disabled` needs
    /// persisting — and must be persisted *first*, so a crash between the two
    /// writes leaves the display unseen and repeats the default rather than
    /// recording "seen" with the disable lost.
    var disabledChanged: Bool
  }

  static func enroll(_ monitors: [FirstSightMonitor],
                     seen: Set<String>,
                     disabled: Set<String>) -> Outcome {
    var outcome = Outcome(seen: seen, disabled: disabled, newlySeen: false, disabledChanged: false)
    for monitor in monitors where !outcome.seen.contains(monitor.id) {
      outcome.seen.insert(monitor.id)
      outcome.newlySeen = true
      // Everything enrolls syncing except software-dimmed Apple-vendor displays
      // — AirPlay targets and Sidecar iPads, which should not start dimming the
      // moment a session begins. They are still listed, so turning one on is a
      // single switch.
      if monitor.prefersDefaultDisabled, !outcome.disabled.contains(monitor.id) {
        outcome.disabled.insert(monitor.id)
        outcome.disabledChanged = true
      }
    }
    return outcome
  }
}
