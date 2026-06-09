import SwiftUI
import AVFoundation

/// Live QR scanner. Calls `onCode` once with the first decoded string.
struct QRScannerView: UIViewControllerRepresentable {
  var onCode: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

  func makeUIViewController(context: Context) -> ScannerVC {
    let vc = ScannerVC()
    vc.onCode = { context.coordinator.handle($0) }
    return vc
  }
  func updateUIViewController(_ vc: ScannerVC, context: Context) {}

  final class Coordinator {
    let onCode: (String) -> Void
    private var fired = false
    init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
    func handle(_ code: String) {
      guard !fired else { return }
      fired = true
      onCode(code)
    }
  }
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onCode: ((String) -> Void)?
  private let session = AVCaptureSession()

  override func viewDidLoad() {
    super.viewDidLoad()
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else { return }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.frame = view.bounds
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput,
                      didOutput metadataObjects: [AVMetadataObject],
                      from connection: AVCaptureConnection) {
    guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let str = obj.stringValue else { return }
    session.stopRunning()
    onCode?(str)
  }
}
