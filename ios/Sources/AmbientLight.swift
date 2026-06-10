import Foundation
import ARKit

/// Reads ambient lighting via ARKit — the only Apple-sanctioned route to an
/// ambient color-temperature value on iOS (True Tone's own sensor has no public
/// or non-jailbreak API). `ambientColorTemperature` is camera-derived, so this is
/// a *suggestion*, not a measurement, and it needs the camera (ARKit can't run at
/// the same time as the color-sync AVCaptureSession — sample before/after that
/// flow, never during).
final class AmbientLight: NSObject, ARSessionDelegate {
  struct Reading: Equatable {
    let kelvin: Double      // ambient color temperature
    let lumens: Double      // ambient intensity
    /// Suggested warm/cool bias for the fine-tune, via the shared mapping.
    var warmCoolBias: Double { AmbientBias.warmCool(forKelvin: kelvin) }
  }

  static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

  private let session = ARSession()
  private var completion: ((Reading?) -> Void)?
  private var framesSeen = 0

  /// Run a short AR session, average a few light estimates, then stop and report.
  /// Completion is called once on the main queue (nil if unsupported/unavailable).
  func read(completion: @escaping (Reading?) -> Void) {
    guard Self.isSupported else { completion(nil); return }
    self.completion = completion
    framesSeen = 0
    accK = 0; accL = 0; n = 0
    let config = ARWorldTrackingConfiguration()
    config.isLightEstimationEnabled = true
    session.delegate = self
    session.run(config, options: [.resetTracking, .removeExistingAnchors])
  }

  // Light estimation needs a few frames to stabilize; average ~10.
  private var accK = 0.0, accL = 0.0, n = 0.0

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    framesSeen += 1
    guard let est = frame.lightEstimate else { return }
    // Skip the first few frames while auto-exposure settles.
    if framesSeen > 5 {
      accK += est.ambientColorTemperature
      accL += est.ambientIntensity
      n += 1
    }
    if n >= 10 { finish() }
    else if framesSeen > 60 { finish() }   // timeout safeguard (~2s)
  }

  func session(_ session: ARSession, didFailWithError error: Error) { finish() }

  private func finish() {
    session.pause()
    let result: Reading? = n > 0 ? Reading(kelvin: accK / n, lumens: accL / n) : nil
    let cb = completion
    completion = nil
    DispatchQueue.main.async { cb?(result) }
  }
}
