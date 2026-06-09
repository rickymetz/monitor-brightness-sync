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
  private var gate = CaptureGate(needed: 6)
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
      hint = "Aim at \(refLabel) and hold steady."
      camera.start()
    case .capture(let id, let label):
      currentDisplayID = id
      gate.reset()
      phase = .capturing(label: label)
      hint = "Photographing \(label)…"
    case .retake(_, let h):
      gate.reset()
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
    latestSamples = samples
    if case .capturing = phase, let id = currentDisplayID {
      if gate.record(found: samples != nil), let s = samples {
        gate.reset()
        client.send(.samples(displayID: id, samples: s))
      }
    }
  }

  /// Manual shutter fallback (capturing phase): send the latest analyzed frame or an error.
  func manualShutter() {
    guard case .capturing = phase, let id = currentDisplayID else { return }
    if let s = latestSamples { client.send(.samples(displayID: id, samples: s)) }
    else { client.send(.error(reason: "no card detected")) }
  }
}
