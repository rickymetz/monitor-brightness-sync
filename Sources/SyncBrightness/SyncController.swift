import CoreGraphics
import Foundation

/// Polls the built-in display's brightness and mirrors it onto every enabled
/// external display over DDC/CI, each through its own calibration curve. Also
/// supports per-monitor enable, manual control, sub-floor gamma dimming, smooth
/// ramping on wake, and reporting monitor state to the UI.
final class SyncController {
  /// (built-in fraction 0...1, external display count) — for the status line.
  var onUpdate: ((Double, Int) -> Void)?
  /// Full per-monitor state, for the control window.
  var onMonitors: (([MonitorState]) -> Void)?

  private let queue = DispatchQueue(label: "com.rick.syncbrightness.sync")
  private let pollInterval: TimeInterval = 0.15
  private let threshold = 0.004
  private let gamma = GammaDimmer()

  private var timer: DispatchSourceTimer?
  private var externals: [ExternalDisplay] = []
  private var builtinID: CGDirectDisplayID?
  private var lastAppliedFraction: Double = -1
  private var isEnabled = true
  private var profiles: [String: BrightnessCurve] = [:]
  private var disabledIDs: Set<String> = []
  private var subFloorDimming = true

  // Calibration: while active, auto-sync is suspended and the target display is
  // driven to `manualExternal` (applied via the timer so drags are coalesced).
  private var calibrating = false
  private var calibrationTargetID: String?
  private var manualExternal = 0.0
  private var lastManualApplied = -1.0
  // Manual brightness requests (sliders, clamshell keys) buffered per display and
  // flushed once per tick so fast drags don't flood the DDC bus.
  private var pendingManual: [String: Double] = [:]

  // MARK: - Configuration

  func setProfiles(_ newProfiles: [String: BrightnessCurve]) {
    queue.async {
      self.profiles = newProfiles
      self.applyProfilesToExternals()
      self.lastAppliedFraction = -1
    }
  }

  func setDisabled(_ ids: Set<String>) {
    queue.async {
      let newlyDisabled = ids.subtracting(self.disabledIDs)
      self.disabledIDs = ids
      for display in self.externals where newlyDisabled.contains(display.id) {
        self.gamma.set(display.cgDisplayID, factor: 1) // don't leave a disabled monitor dimmed
      }
      self.lastAppliedFraction = -1
      self.reportMonitors()
    }
  }

  func setSubFloorDimming(_ on: Bool) {
    queue.async {
      self.subFloorDimming = on
      if !on {
        for display in self.externals { self.gamma.set(display.cgDisplayID, factor: 1) }
      }
      self.lastAppliedFraction = -1
    }
  }

  func setEnabled(_ enabled: Bool) {
    queue.async {
      self.isEnabled = enabled
      if enabled { self.lastAppliedFraction = -1 }
    }
  }

  // MARK: - Calibration

  func setCalibrating(_ active: Bool, targetID: String? = nil) {
    queue.async {
      self.calibrating = active
      self.calibrationTargetID = targetID
      self.lastManualApplied = -1
      self.lastAppliedFraction = -1
    }
  }

  func setManualExternal(_ fraction: Double) {
    queue.async { self.manualExternal = max(0.0, min(1.0, fraction)) }
  }

  // MARK: - Manual control (per-monitor sliders, external-only mode)

  func setManual(id: String, fraction: Double) {
    queue.async { self.pendingManual[id] = max(0.0, min(1.0, fraction)) }
  }

  func setManualAll(fraction: Double) {
    queue.async {
      let f = max(0.0, min(1.0, fraction))
      for display in self.externals where !self.disabledIDs.contains(display.id) {
        self.pendingManual[display.id] = f
      }
    }
  }

  private func flushPendingManual() {
    guard !pendingManual.isEmpty else { return }
    let pending = pendingManual
    pendingManual.removeAll()
    for (id, fraction) in pending {
      guard let display = externals.first(where: { $0.id == id }) else { continue }
      gamma.set(display.cgDisplayID, factor: 1)
      display.setBrightness(fraction: fraction)
    }
    reportMonitors()
  }

  // MARK: - Lifecycle

  func start() {
    queue.async {
      self.rescanDisplays()
      self.registerReconfigurationCallback()

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: self.pollInterval)
      timer.setEventHandler { [weak self] in self?.tick() }
      self.timer = timer
      timer.resume()
    }
  }

  /// Re-apply after wake — monitors come back slowly and may have forgotten
  /// their brightness, so rescan and ramp a few times.
  func wake() {
    queue.async {
      self.rescanDisplays()
      self.applyNow(ramp: true)
    }
    for delay in [2.0, 5.0] {
      queue.asyncAfter(deadline: .now() + delay) { self.applyNow(ramp: true) }
    }
  }

  /// Restore gamma before exit.
  func shutdown() {
    queue.sync { self.gamma.reset() }
  }

  // MARK: - Polling

  private func tick() {
    flushPendingManual()
    guard let builtinID, !externals.isEmpty else { return }

    if calibrating {
      guard abs(manualExternal - lastManualApplied) >= threshold else { return }
      lastManualApplied = manualExternal
      for display in externals where calibrationTargetID == nil || display.id == calibrationTargetID {
        gamma.set(display.cgDisplayID, factor: 1) // pure DDC while calibrating
        display.setBrightness(fraction: manualExternal)
      }
      reportMonitors()
      return
    }

    guard isEnabled else { return }
    guard let fraction = BuiltinBrightness.fraction(of: builtinID) else { return }
    guard abs(fraction - lastAppliedFraction) >= threshold else { return }
    applyNow(ramp: false, fraction: fraction)
  }

  private func applyNow(ramp: Bool, fraction known: Double? = nil) {
    guard !calibrating, isEnabled, let builtinID, !externals.isEmpty else { return }
    guard let fraction = known ?? BuiltinBrightness.fraction(of: builtinID) else { return }
    lastAppliedFraction = fraction
    for display in externals where !disabledIDs.contains(display.id) {
      applyToDisplay(display, builtin: fraction, ramp: ramp)
    }
    let count = externals.count
    reportMonitors()
    DispatchQueue.main.async { self.onUpdate?(fraction, count) }
  }

  // Never gamma-dim all the way to black — a fully dark external looks like a
  // disconnected monitor. Keep a small visible floor.
  private let minGammaFactor = 0.15

  private func applyToDisplay(_ display: ExternalDisplay, builtin: Double, ramp: Bool) {
    let zero = display.curve.zeroBuiltin
    if subFloorDimming, zero > 0, builtin < zero {
      // Below the DDC floor: hold DDC at minimum and dim further via gamma.
      display.setBrightness(fraction: 0, ramp: ramp)
      gamma.set(display.cgDisplayID, factor: max(minGammaFactor, builtin / zero))
    } else {
      gamma.set(display.cgDisplayID, factor: 1)
      display.setBrightness(fraction: display.curve.external(for: builtin), ramp: ramp)
    }
  }

  private func rescanDisplays() {
    builtinID = BuiltinBrightness.builtinDisplayID()
    externals = DDC.externalDisplays()
    for display in externals {
      display.refreshMaxBrightness()
      display.curve = profiles[display.id] ?? .default
    }
    lastAppliedFraction = -1
    let count = externals.count
    reportMonitors()
    DispatchQueue.main.async { self.onUpdate?(-1, count) }
  }

  private func applyProfilesToExternals() {
    for display in externals {
      display.curve = profiles[display.id] ?? .default
    }
  }

  private func reportMonitors() {
    let states = externals.map {
      MonitorState(id: $0.id, name: $0.name,
                   enabled: !disabledIDs.contains($0.id),
                   healthy: $0.lastWriteOK,
                   brightness: $0.currentFraction)
    }
    DispatchQueue.main.async { self.onMonitors?(states) }
  }

  private func registerReconfigurationCallback() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
      guard let userInfo else { return }
      guard flags.contains(.setMainFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
      let controller = Unmanaged<SyncController>.fromOpaque(userInfo).takeUnretainedValue()
      controller.queue.async { controller.rescanDisplays() }
    }, context)
  }
}
