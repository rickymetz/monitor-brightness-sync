import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import UIKit

/// Camera capture with lockable WB/exposure. Two outputs share one locked
/// transform:
///   • a video-data output drives the live framing gate (FieldSampler over the
///     8-bit preview — cheap, continuous, used only to know the camera is pressed
///     flat against a bright, uniform field);
///   • a photo output captures a non-ProRAW **Bayer RAW** still on demand, which
///     `captureRAWField` reduces to *linear* RGB via the shared `BayerField`.
///     RAW is what makes the measurement linear (R² ≈ 0.998) instead of the
///     processed 8-bit BGRA pipeline (~0.75–0.88); that linearity is the single
///     biggest measurement-accuracy lever.
final class CameraController: NSObject, ObservableObject {
  let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private let sampleQueue = DispatchQueue(label: "mbsync.frames")
  private let ciContext = CIContext()
  private var device: AVCaptureDevice?

  /// True when the photo output negotiated a usable Bayer RAW format.
  private(set) var rawAvailable = false
  private(set) var rawIsProRAW = false
  private var rawPixelFormat: OSType = 0
  /// Diagnostics: how many RAW pixel formats the output offered when we probed.
  private(set) var rawFormatCount = 0
  /// One-shot RAW-capability report (preset, ProRAW support, format list) for the log.
  var onDiagnostics: ((String) -> Void)?

  /// Called on the MAIN queue for each analyzed preview frame (framing gate).
  var onFrame: ((FieldMeasure) -> Void)?
  /// Latest preview frame as a CGImage (main queue) — used by the side-by-side debug check.
  @Published var lastImage: CGImage?

  // One in-flight RAW capture at a time; its delegate is retained here.
  private var rawDelegate: RawCaptureDelegate?

  func start() {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: device) else { return }
    self.device = device
    session.beginConfiguration()
    if session.canAddInput(input) { session.addInput(input) }
    if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      // ProRAW is explicitly avoided (it's fused, not raw-linear). Must be set
      // during configuration, and only when supported.
      if #available(iOS 14.3, *), photoOutput.isAppleProRAWSupported {
        photoOutput.isAppleProRAWEnabled = false
      }
    }
    session.commitConfiguration()

    // Pin orientation to portrait so the analyzer's white-fiducial quadrant assumption holds.
    if let conn = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, *) {
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
      } else if conn.isVideoOrientationSupported {
        conn.videoOrientation = .portrait
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.session.startRunning()
      // availableRawPhotoPixelFormatTypes is only valid once the session is
      // running and connections are established — query it here, not during config.
      self?.discoverRawFormat()
    }
  }

  /// Enumerate RAW formats. ProRAW is left OFF (pinned in `start()`), so the list
  /// is the device's **Bayer** formats — exactly what we want (linear, near-sensor,
  /// no fusion). We deliberately DON'T toggle `isAppleProRAWEnabled` to also probe
  /// the ProRAW list: the begin/commitConfiguration churn that toggling requires
  /// leaves `availableRawPhotoPixelFormatTypes` transiently EMPTY, which made every
  /// capture miss RAW (`no-raw(0)`) even though Bayer was available. Reading the
  /// stable list once keeps it populated through capture.
  private func discoverRawFormat(_ label: String = "probe") {
    var proRawSupported = false
    let bayerFmts = photoOutput.availableRawPhotoPixelFormatTypes
    if #available(iOS 14.3, *) { proRawSupported = photoOutput.isAppleProRAWSupported }

    if let b = bayerFmts.first {
      rawPixelFormat = b; rawAvailable = true; rawIsProRAW = false
    }
    rawFormatCount = bayerFmts.count

    let preset = session.sessionPreset.rawValue
    let bStr = bayerFmts.map { Self.fourCC($0) }.joined(separator: ",")
    let dim = device.map { d -> String in
      let d2 = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
      return "\(d2.width)x\(d2.height)"
    } ?? "—"
    let chosen = rawAvailable ? "bayer" : "none"
    let diag = "raw-\(label) preset=\(preset) proRawSupported=\(proRawSupported) bayer=[\(bStr)] count=\(bayerFmts.count) chosen=\(chosen) activeFmt=\(dim)"
    DispatchQueue.main.async { self.onDiagnostics?(diag) }
  }

  func stop() { session.stopRunning() }

  /// Lock white balance + exposure + focus so all captures share one transform.
  func lock() {
    guard let device else { return }
    try? device.lockForConfiguration()
    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
    if device.isWhiteBalanceModeSupported(.locked) {
      device.whiteBalanceMode = .locked
    } else if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
      device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
    }
    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
    device.unlockForConfiguration()
    discoverRawFormat("postlock")
    // RAW photo capture requires the `.photo` preset AND a RAW-capable active format.
    // As AE/AWB settle under `.photo`, the session auto-switches to a non-RAW format
    // (postlock shows bayer=[]). Now that exposure is LOCKED (AE can't re-converge),
    // re-commit the `.photo` preset to bounce the session back to its default
    // RAW-capable photo format; it then stays put. Pinning via `device.activeFormat`
    // is NOT an option — it forces input-priority, which disables RAW entirely.
    if photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
      session.beginConfiguration()
      if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
      session.commitConfiguration()
      discoverRawFormat("postcommit")
    }
  }

  func enableAutofocus() {
    guard let device else { return }
    try? device.lockForConfiguration()
    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
    device.unlockForConfiguration()
  }

  /// Capture one RAW still and reduce its central region to LINEAR RGB. Falls back
  /// to `nil` if RAW is unavailable or the capture fails, so the caller can use the
  /// 8-bit preview average instead. Completion is delivered on the main queue.
  /// Completion gives the linear-RGB reduction (or nil on any miss → 8-bit
  /// fallback) plus a short `source` tag describing what happened, for diagnostics.
  func captureRAWField(completion: @escaping (RGB?, String) -> Void) {
    // Use the format chosen at probe time (Bayer preferred, else ProRAW), but
    // revalidate against the CURRENT list — it can change, and capturePhoto raises
    // on an invalid format.
    let types = photoOutput.availableRawPhotoPixelFormatTypes
    var fmt = rawPixelFormat
    if fmt == 0 || !types.contains(fmt) { fmt = types.first ?? 0 }
    guard fmt != 0 else { completion(nil, "8bit:no-raw(\(types.count))"); return }
    guard photoOutput.connection(with: .video)?.isActive == true else {
      completion(nil, "8bit:no-connection"); return
    }
    let settings = AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: nil)
    settings.flashMode = .off
    let pattern = Self.pattern(for: fmt)
    let white = Self.whiteLevel(for: fmt)
    let delegate = RawCaptureDelegate(pattern: pattern, whiteLevel: white) { [weak self] rgb, reason in
      self?.rawDelegate = nil
      DispatchQueue.main.async { completion(rgb, reason) }
    }
    rawDelegate = delegate
    photoOutput.capturePhoto(with: settings, delegate: delegate)
  }

  // MARK: - RAW format helpers

  /// Map a Bayer RAW OSType to its CFA layout (FourCC: 'rgg4','grb4','bgg4','gbr4'
  /// and 16-bit variants share the same colour-order prefix).
  static func pattern(for osType: OSType) -> BayerPattern {
    switch fourCCPrefix(osType) {
    case "rgg": return .rggb
    case "grb": return .grbg
    case "bgg": return .bggr
    case "gbr": return .gbrg
    default: return .rggb
    }
  }

  /// White (saturation) level from the bit depth encoded in the format.
  static func whiteLevel(for osType: OSType) -> Double {
    // FourCC ends in the bit depth: '4'→14-bit, '6'→16-bit, '0'→10-bit, '2'→12-bit.
    let s = fourCC(osType)
    switch s.last {
    case "0": return 1023      // 10-bit
    case "2": return 4095      // 12-bit
    case "4": return 16383     // 14-bit
    case "6": return 65535     // 16-bit
    default: return 16383
    }
  }

  private static func fourCC(_ t: OSType) -> String {
    let bytes = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
  }
  private static func fourCCPrefix(_ t: OSType) -> String { String(fourCC(t).prefix(3)).lowercased() }
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
    let field = FieldSampler.measure(image: cg)
    DispatchQueue.main.async { self.onFrame?(field); self.lastImage = cg }
  }
}

/// Human-readable FourCC of an OSType (e.g. 'rgg4'), for diagnostics.
private func fourCCString(_ t: OSType) -> String {
  let bytes = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
  return String(bytes: bytes, encoding: .ascii) ?? "\(t)"
}

/// Reduces one RAW photo's Bayer buffer to linear RGB off the main thread.
private final class RawCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let pattern: BayerPattern
  private let whiteLevel: Double
  private let done: (RGB?, String) -> Void

  init(pattern: BayerPattern, whiteLevel: Double, done: @escaping (RGB?, String) -> Void) {
    self.pattern = pattern
    self.whiteLevel = whiteLevel
    self.done = done
  }

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    if let error { done(nil, "8bit:capture-error(\(error.localizedDescription.prefix(20)))"); return }
    guard let pb = photo.pixelBuffer else {
      // For some configs RAW data isn't surfaced as pixelBuffer — diagnose it.
      done(nil, "8bit:pixelbuffer-nil(raw=\(photo.isRawPhoto))"); return
    }
    // Black level (pedestal) from metadata when present; refines linearity. The
    // exact key isn't part of the public buffer, so default to 0 — the dominant
    // RAW benefit (no tone curve) holds regardless, and the pedestal nearly
    // cancels when two displays are ratioed through the same camera.
    let black = (photo.metadata["BlackLevel"] as? Double) ?? 0
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    guard let rgb = Self.reduce(pixelBuffer: pb, pattern: pattern, blackLevel: black, whiteLevel: whiteLevel) else {
      done(nil, "8bit:reduce-nil(fmt=\(fourCCString(fmt)))"); return
    }
    done(rgb, "raw(\(fourCCString(fmt)))")
  }

  /// Read a single-plane 16-bit Bayer buffer into [Double] and average the centre.
  static func reduce(pixelBuffer pb: CVPixelBuffer, pattern: BayerPattern,
                     blackLevel: Double, whiteLevel: Double) -> RGB? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    // Bayer RAW is a single non-planar 16-bit plane; bail (→ 8-bit fallback) on any
    // other layout so the strided UInt16 reads below can't run out of bounds.
    guard !CVPixelBufferIsPlanar(pb), w > 1, h > 1, stride >= w * 2,
          let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    // Bayer RAW is one 16-bit sample per pixel.
    var pixels = [Double](repeating: 0, count: w * h)
    for y in 0..<h {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
      let dst = y * w
      for x in 0..<w { pixels[dst + x] = Double(row[x]) }
    }
    return BayerField.average(pixels: pixels, width: w, height: h, pattern: pattern,
                              blackLevel: blackLevel, whiteLevel: whiteLevel, centerFraction: 0.6)
  }
}
