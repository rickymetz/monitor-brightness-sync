import SwiftUI

@main
struct MBSyncApp: App {
  @StateObject private var client: ColorSyncClient
  @StateObject private var camera: CameraController
  @StateObject private var coordinator: SessionCoordinator

  init() {
    let c = ColorSyncClient()
    let cam = CameraController()
    _client = StateObject(wrappedValue: c)
    _camera = StateObject(wrappedValue: cam)
    _coordinator = StateObject(wrappedValue: SessionCoordinator(client: c, camera: cam))
  }

  var body: some Scene {
    WindowGroup {
      switch coordinator.phase {
      case .pairing: PairingView(client: client)
      case .awaitingLock, .capturing: CaptureView(coordinator: coordinator)
      case .done: DoneView()
      }
    }
  }
}
