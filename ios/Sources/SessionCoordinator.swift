import Foundation
import SwiftUI

/// Maps incoming MacToPhone messages to UI state + camera actions, and emits
/// PhoneToMac replies. Auto-capture gated by CaptureGate.
@MainActor
final class SessionCoordinator: ObservableObject {
  enum Phase: Equatable {
    case pairing
    case awaitingLock(referenceLabel: String)
    case capturing(label: String)
    case done
  }
  @Published var phase: Phase = .pairing
  @Published var hint: String = ""
  @Published var latestSamples: PatchSamples?

  let client: ColorSyncClient
  let camera: CameraController
  private var currentDisplayID: String?

  init(client: ColorSyncClient, camera: CameraController) {
    self.client = client
    self.camera = camera
    client.onMessage = { [weak self] in self?.handle($0) }
    camera.onFrame = { [weak self] in self?.onFrame($0) }
  }

  private func handle(_ msg: MacToPhone) {
    switch msg {
    case .prepareLock(let refLabel):
      phase = .awaitingLock(referenceLabel: refLabel)
      hint = "Press the camera flat against \(refLabel), then tap Lock & Start."
      camera.start()
    case .capture(let id, let label):
      currentDisplayID = id
      phase = .capturing(label: label)
      hint = "Press the camera flat against \(label), then tap Capture."
    case .retake(_, let h):
      hint = h
    case .done:
      phase = .done
      camera.stop()
    }
  }

  /// Called when in awaitingLock and the user triggers the lock.
  func confirmLock() {
    camera.lock()
    client.send(.locked)
    hint = "Locked. Waiting for the Mac…"
  }

  private func onFrame(_ samples: PatchSamples?) {
    // Non-nil when a steady, uniform bright field is in view (camera on a screen).
    latestSamples = samples
  }

  /// Whether a steady field is currently in view (drives the Capture button).
  var fieldReady: Bool { latestSamples != nil }

  /// Capture the current display — the user taps this while pressing the camera
  /// flat against that display's gray screen. Explicit, one tap per display.
  func capture() {
    guard case .capturing = phase, let id = currentDisplayID, let s = latestSamples else {
      hint = "Hold the camera flat against the screen, then tap Capture."
      return
    }
    client.send(.samples(displayID: id, samples: s))
    hint = "Captured. Move to the next screen…"
  }
}
