import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import UIKit

/// Camera capture with lockable WB/exposure. Runs the shared PatchCardAnalyzer on
/// preview frames and reports each analyzer outcome (nil if no card). The owner
/// decides auto-capture (via CaptureGate). Analysis runs off the main thread;
/// results are delivered on the main queue.
final class CameraController: NSObject, ObservableObject {
  let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let sampleQueue = DispatchQueue(label: "mbsync.frames")
  private let ciContext = CIContext()
  private var device: AVCaptureDevice?

  /// Called on the MAIN queue for each analyzed frame with the measured field.
  var onFrame: ((FieldMeasure) -> Void)?

  func start() {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: device) else { return }
    self.device = device
    session.beginConfiguration()
    if session.canAddInput(input) { session.addInput(input) }
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    session.commitConfiguration()
    // Pin orientation to portrait so the analyzer's white-fiducial quadrant assumption holds.
    if let conn = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, *) {
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
      } else if conn.isVideoOrientationSupported {
        conn.videoOrientation = .portrait
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
  }

  func stop() { session.stopRunning() }

  /// Lock white balance + exposure so all subsequent captures share one transform.
  func lock() {
    guard let device else { return }
    try? device.lockForConfiguration()
    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
    // White balance: prefer .locked mode; else pin current device gains explicitly.
    if device.isWhiteBalanceModeSupported(.locked) {
      device.whiteBalanceMode = .locked
    } else if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
      device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
    }
    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
    device.unlockForConfiguration()
  }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let ci = CIImage(cvPixelBuffer: pb)
    guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
      DispatchQueue.main.async { self.onFrame?(FieldMeasure(average: RGB(r: 0, g: 0, b: 0), uniformBright: false)) }
      return
    }
    // With the camera locked, the average of a fullscreen neutral field IS the
    // display's chroma at that level. The Mac drives which level is shown.
    let field = FieldSampler.measure(image: cg)
    DispatchQueue.main.async { self.onFrame?(field) }
  }
}
