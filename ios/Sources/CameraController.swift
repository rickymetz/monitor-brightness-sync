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

  /// Called on the MAIN queue for each analyzed frame (nil = no card found).
  var onFrame: ((PatchSamples?) -> Void)?

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
    DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
  }

  func stop() { session.stopRunning() }

  /// Lock white balance + exposure so all subsequent captures share one transform.
  func lock() {
    guard let device else { return }
    try? device.lockForConfiguration()
    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
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
      DispatchQueue.main.async { self.onFrame?(nil) }
      return
    }
    let samples = PatchCardAnalyzer.sample(image: cg)
    DispatchQueue.main.async { self.onFrame?(samples) }
  }
}
