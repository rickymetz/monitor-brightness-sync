import Foundation

/// Transport-agnostic color-sync coordinator. Sequences: lock -> capture each
/// display -> compute corrections. Pure logic; UI/display side effects via callbacks.
final class ColorSyncSession {
  enum State: Equatable { case idle, awaitingLock, capturing(index: Int), done }

  let displays: [DisplayRef]
  let referenceID: String
  private weak var peer: ColorSyncPeer?

  private(set) var state: State = .idle
  private(set) var collected: [String: PatchSamples] = [:]

  /// Show the patch card fullscreen on this display id.
  var onShowCard: ((String) -> Void)?
  /// Show the neutral mid-gray lock target on the reference display id.
  var onPrepareReference: ((String) -> Void)?
  /// Final corrections, ready to apply + persist.
  var onComplete: (([String: ColorCorrection]) -> Void)?

  init(displays: [DisplayRef], referenceID: String, peer: ColorSyncPeer) {
    self.displays = displays
    self.referenceID = referenceID
    self.peer = peer
  }

  func start() {
    guard state == .idle, !displays.isEmpty else { return }
    state = .awaitingLock
    onPrepareReference?(referenceID)
    let refLabel = displays.first(where: { $0.id == referenceID })?.label ?? "the reference"
    peer?.send(.prepareLock(referenceLabel: refLabel))
  }

  func handle(_ message: PhoneToMac) {
    switch (state, message) {
    case (.awaitingLock, .locked):
      beginCapture(index: 0)

    case (.capturing(let i), .samples(let id, let s)) where id == displays[i].id:
      collected[id] = s
      if i + 1 < displays.count { beginCapture(index: i + 1) } else { finish() }

    case (.capturing(let i), .error):
      peer?.send(.retake(displayID: displays[i].id, hint: "Less angle, avoid glare; fill the frame."))

    default:
      break // ignore out-of-order messages
    }
  }

  private func beginCapture(index i: Int) {
    state = .capturing(index: i)
    onShowCard?(displays[i].id)
    peer?.send(.capture(displayID: displays[i].id, label: displays[i].label))
  }

  private func finish() {
    let measurements = collected.map { DisplayMeasurement(displayID: $0.key, samples: $0.value) }
    let corrections = ColorMatcher.corrections(measurements: measurements, referenceID: referenceID)
    state = .done
    peer?.send(.done)
    onComplete?(corrections)
  }
}
