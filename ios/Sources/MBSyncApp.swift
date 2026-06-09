import SwiftUI

@main
struct MBSyncApp: App {
  @StateObject private var client: ColorSyncClient
  @StateObject private var camera: CameraController
  @StateObject private var coordinator: SessionCoordinator
  @State private var showDebug = false

  init() {
    let c = ColorSyncClient()
    let cam = CameraController()
    _client = StateObject(wrappedValue: c)
    _camera = StateObject(wrappedValue: cam)
    _coordinator = StateObject(wrappedValue: SessionCoordinator(client: c, camera: cam))
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if showDebug {
          SideBySideView(camera: camera, client: client, onClose: { showDebug = false })
        } else {
          switch coordinator.phase {
          case .pairing: PairingView(client: client, onDebug: { showDebug = true })
          case .awaitingLock, .capturing: CaptureView(coordinator: coordinator)
          case .done: DoneView(onVerify: { showDebug = true })
          }
        }
      }
      // Launched/foregrounded via the system Camera scanning an mbsync:// QR.
      .onOpenURL { url in
        if let payload = PairingPayload.parse(url.absoluteString) {
          client.connect(payload)
        }
      }
    }
  }
}
