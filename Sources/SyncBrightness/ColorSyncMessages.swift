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
  // `source` reports how the field was measured: "raw" (linear Bayer) or an 8-bit
  // fallback reason (e.g. "8bit:unavailable", "8bit:pixelbuffer-nil") — diagnostics.
  case measured(level: Int, r: Double, g: Double, b: Double, source: String)
  case samples(displayID: String, samples: PatchSamples)  // legacy single-field path
  case beginVerify                                         // phone opened side-by-side; show test field
  case sideBySide(aR: Double, aG: Double, aB: Double, bR: Double, bG: Double, bB: Double)
  case ambient(kelvin: Double)                             // ARKit ambient CCT → suggested warm/cool bias
  case debug(message: String)                              // free-form diagnostics → Mac log file
  case error(reason: String)
}

/// Abstraction over the wire so the session is testable with a fake peer.
protocol ColorSyncPeer: AnyObject {
  func send(_ message: MacToPhone)
}
