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
  /// Status of the optional ambient-light (ARKit) sampling on the Done screen.
  @Published private(set) var ambientStatus: String?

  let client: ColorSyncClient
  let camera: CameraController
  private let ambient = AmbientLight()
  private var currentDisplayID: String?
  private var lastField: FieldMeasure?

  init(client: ColorSyncClient, camera: CameraController) {
    self.client = client
    self.camera = camera
    client.onMessage = { [weak self] in self?.handle($0) }
    camera.onFrame = { [weak self] in self?.onFrame($0) }
    camera.onDiagnostics = { [weak self] diag in
      Task { @MainActor in self?.client.send(.debug(message: diag)) }
    }
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
      // The Mac has a field showing; capture a linear RAW still and report it.
      // Falls back to the 8-bit preview average if RAW is unavailable/failed.
      hint = "Measuring… hold steady (\(level + 1)/6)."
      let fallback = lastField?.average ?? RGB(r: 0, g: 0, b: 0)
      camera.captureRAWField { [weak self] rgb, source in
        Task { @MainActor in
          guard let self else { return }
          let a = rgb ?? fallback
          self.client.send(.measured(level: level, r: a.r, g: a.g, b: a.b, source: source))
        }
      }
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

  /// Optional, on the Done screen: read room lighting via ARKit and send the
  /// ambient color temperature to the Mac as a suggested warm/cool bias. Safe here
  /// because the capture session is already stopped (ARKit needs the camera too).
  func sampleAmbient() {
    guard AmbientLight.isSupported else { ambientStatus = "Ambient light not available on this device."; return }
    ambientStatus = "Reading room light… point the phone at your scene."
    ambient.read { [weak self] reading in
      guard let self else { return }
      guard let reading else { self.ambientStatus = "Couldn't read ambient light."; return }
      self.client.send(.ambient(kelvin: reading.kelvin))
      self.ambientStatus = String(format: "Room ≈ %.0fK → sent warm/cool %+.2f to the Mac.",
                                  reading.kelvin, reading.warmCoolBias)
    }
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
