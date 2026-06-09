import SwiftUI

struct CaptureView: View {
  @ObservedObject var coordinator: SessionCoordinator

  var body: some View {
    ZStack(alignment: .bottom) {
      CameraPreviewView(session: coordinator.camera.session)
        .ignoresSafeArea()
      VStack(spacing: 12) {
        Text(coordinator.hint)
          .font(.headline).foregroundStyle(.white)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(.black.opacity(0.5), in: Capsule())
        if case .awaitingLock = coordinator.phase {
          Button("Lock & Start") { coordinator.confirmLock() }
            .buttonStyle(.borderedProminent)
        }
        if case .capturing = coordinator.phase {
          Button("Capture manually") { coordinator.manualShutter() }
            .buttonStyle(.bordered).tint(.white)
        }
      }
      .padding(.bottom, 40)
    }
  }
}
