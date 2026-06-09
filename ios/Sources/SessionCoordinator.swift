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
  /// A steady, uniform bright field is in view (camera pressed to a screen).
  @Published private(set) var fieldReady = false
  /// The Mac is driving the gray-ramp for the current display (no tap needed).
  @Published private(set) var ramping = false

  let client: ColorSyncClient
  let camera: CameraController
  private var currentDisplayID: String?
  private var lastField: FieldMeasure?

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
      ramping = false
      phase = .capturing(label: label)
      hint = "Press the camera flat against \(label), then tap Capture."
    case .measure(let level):
      // The Mac has a ramp level showing; report what the camera currently sees.
      let a = lastField?.average ?? RGB(r: 0, g: 0, b: 0)
      client.send(.measured(level: level, r: a.r, g: a.g, b: a.b))
      hint = "Measuring… hold steady (\(level + 1)/3)."
    case .retake(_, let h):
      ramping = false
      hint = h
    case .done:
      ramping = false
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

  private func onFrame(_ field: FieldMeasure) {
    lastField = field
    let ready = !ramping && field.uniformBright
    if ready != fieldReady { fieldReady = ready }
  }

  /// One tap per display: start the Mac-driven gray-ramp. Hold the camera against
  /// the screen through the whole cycle; the Mac steps the levels automatically.
  func capture() {
    guard case .capturing = phase, let id = currentDisplayID, fieldReady else {
      hint = "Hold the camera flat against the screen, then tap Capture."
      return
    }
    ramping = true
    fieldReady = false
    client.send(.beginRamp(displayID: id))
    hint = "Hold steady against the screen — measuring…"
  }
}
