import Foundation

/// A display to calibrate (reference first). `id` is ExternalDisplay.id or "builtin".
struct DisplayRef: Equatable, Codable {
  let id: String
  let label: String
}

/// Coordinator (Mac) -> capture client (phone).
enum MacToPhone: Equatable, Codable {
  case prepareLock(referenceLabel: String)
  case capture(displayID: String, label: String)   // prompt: press camera + tap Capture
  case measure(level: Int)                          // measure the currently shown ramp level now
  case retake(displayID: String, hint: String)
  case done
}

/// Capture client (phone) -> coordinator (Mac).
enum PhoneToMac: Equatable, Codable {
  case paired
  case locked
  case beginRamp(displayID: String)                 // user tapped Capture; start the ramp
  case measured(level: Int, r: Double, g: Double, b: Double)
  case samples(displayID: String, samples: PatchSamples)  // legacy single-field path
  case error(reason: String)
}

/// Abstraction over the wire so the session is testable with a fake peer.
protocol ColorSyncPeer: AnyObject {
  func send(_ message: MacToPhone)
}
