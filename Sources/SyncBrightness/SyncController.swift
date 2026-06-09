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
  /// Fired (with a display id) when a reconcile read finds the monitor's
  /// brightness was changed outside the app — e.g. via its own buttons.
  var onExternalChangedExternally: ((String) -> Void)?

  private let queue = DispatchQueue(label: "com.rick.syncbrightness.sync")
  private let pollInterval: TimeInterval = 0.15
  private let threshold = 0.004
  private let gamma = DisplayColorState()

  private var timer: DispatchSourceTimer?
  private var externals: [ExternalDisplay] = []
  private var builtinID: CGDirectDisplayID?
  private var lastAppliedFraction: Double = -1
  private var isEnabled = true
  private var profiles: [String: BrightnessCurve] = [:]
  private var disabledIDs: Set<String> = []
  private var subFloorDimming = true
  private var allowBlackout = false

  // Calibration: while active, auto-sync is suspended and the target display is
  // driven to `manualExternal` (applied via the timer so drags are coalesced).
  private var calibrating = false
  private var calibrationTargetID: String?
  private var manualExternal = 0.0
  private var lastManualApplied = -1.0
  // Manual brightness requests (per-monitor sliders) buffered per display and
  // flushed once per tick so fast drags don't flood the DDC bus.
  private var pendingManual: [String: Double] = [:]
  // Clamshell / external-only brightness level, also coalesced per tick.
  private var pendingExternalOnly: Double?
  private let clamshellFloor = 0.15
  // Reconcile: when we're not driving a display, periodically re-read its DDC
  // brightness so our state matches changes made on the monitor's own buttons.
  private var reconcileCounter = 0
  private let reconcileEveryTicks = 66 // ~10s at the 0.15s poll interval — gentle on the DDC bus

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
        display.clearGammaFollow()
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

  func setAllowBlackout(_ on: Bool) {
    queue.async {
      self.allowBlackout = on
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

  private var savedBuiltinFraction: Double?

  /// Hold every display at one known brightness for color measurement: pause sync
  /// (like calibration) and drive the built-in + externals to `level`. The
  /// brightest gray field then sits at a consistent, clip-safe operating point on
  /// each display. Restore with `endFixedBrightness()`.
  func beginFixedBrightness(_ level: Double) {
    queue.async {
      let lvl = max(0.0, min(1.0, level))
      if let id = self.builtinID { self.savedBuiltinFraction = BuiltinBrightness.fraction(of: id) }
      self.calibrating = true
      self.calibrationTargetID = nil
      self.manualExternal = lvl
      for display in self.externals { _ = display.setBrightness(fraction: lvl) }
      if let id = self.builtinID { _ = BuiltinBrightness.setFraction(lvl, of: id) }
    }
  }

  /// Restore the built-in's brightness and resume sync (externals re-mirror it).
  func endFixedBrightness() {
    queue.async {
      if let id = self.builtinID, let saved = self.savedBuiltinFraction {
        _ = BuiltinBrightness.setFraction(saved, of: id)
      }
      self.savedBuiltinFraction = nil
      self.calibrating = false
      self.calibrationTargetID = nil
      self.lastManualApplied = -1
      self.lastAppliedFraction = -1
    }
  }

  // MARK: - Manual control (per-monitor sliders, external-only mode)

  func setManual(id: String, fraction: Double) {
    queue.async { self.pendingManual[id] = max(0.0, min(1.0, fraction)) }
  }

  /// Drive the external(s) directly in clamshell/external-only mode. There's no
  /// built-in to mirror, so the level is the brightness: it maps to DDC, with
  /// sub-floor gamma dimming below the floor when "extra dimming" is on.
  func applyExternalOnly(level: Double) {
    queue.async { self.pendingExternalOnly = max(0.0, min(1.0, level)) }
  }

  private func flushPendingManual() {
    guard !pendingManual.isEmpty else { return }
    let pending = pendingManual
    pendingManual.removeAll()
    for (id, fraction) in pending {
      guard let display = externals.first(where: { $0.id == id }) else { continue }
      // floor 0 → pure DDC, but still falls back to gamma if the write is refused.
      setLevel(display, ddcFraction: fraction, dimInput: fraction, floor: 0)
    }
    reportMonitors()
  }

  private func flushPendingExternalOnly() {
    guard let level = pendingExternalOnly else { return }
    pendingExternalOnly = nil
    // Clamshell: the level is the brightness directly (no built-in to mirror).
    for display in externals where !disabledIDs.contains(display.id) {
      setLevel(display, ddcFraction: level, dimInput: level, floor: clamshellFloor)
    }
    reportMonitors()
  }

  /// When we're not actively driving the externals (sync paused, or clamshell
  /// between key presses), occasionally re-read their DDC brightness so our
  /// state reflects changes made on the monitor's own buttons. Skipped while we
  /// own the value (active sync) to avoid loading the bus and fighting writes.
  private func reconcileExternalLevels() {
    reconcileCounter += 1
    guard reconcileCounter >= reconcileEveryTicks else { return }
    reconcileCounter = 0
    guard !calibrating, !externals.isEmpty else { return }
    let activelyDriving = isEnabled && builtinID != nil
    guard !activelyDriving else { return }

    var changed = false
    for display in externals where !disabledIDs.contains(display.id) && !display.followsViaGamma && display.readResponsive {
      guard let result = DDC.read(service: display.service, command: kVCPBrightness), result.max > 0 else { continue }
      let observed = max(0.0, min(1.0, Double(result.current) / Double(result.max)))
      if let known = display.lastSetFraction, abs(observed - known) < 0.02 { continue }
      display.syncObservedLevel(observed)
      changed = true
      DispatchQueue.main.async { self.onExternalChangedExternally?(display.id) }
    }
    if changed { reportMonitors() }
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
    // Displays can enumerate a moment after launch (e.g. booting into clamshell),
    // and a display already present at that point fires no "added" event. Retry
    // the scan a few times if nothing was found yet.
    for delay in [1.5, 4.0, 8.0] {
      queue.asyncAfter(deadline: .now() + delay) {
        if self.externals.isEmpty { self.rescanDisplays() }
      }
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
    flushPendingExternalOnly()
    reconcileExternalLevels()
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

  /// Drive a display to `ddcFraction`, except when sub-floor dimming is on and
  /// `dimInput` is below `floor` — then hold DDC at minimum and dim further via
  /// gamma (clamped so it never blacks out). Shared by sync and clamshell modes.
  /// If the DDC write is refused, fall back to following the built-in entirely
  /// via software gamma so non-DDC displays still track brightness.
  private func setLevel(_ display: ExternalDisplay, ddcFraction: Double, dimInput: Double, floor: Double, ramp: Bool = false) {
    let belowFloor = subFloorDimming && floor > 0 && dimInput < floor
    let minGamma = allowBlackout ? 0.0 : minGammaFactor
    let wroteOK = display.setBrightness(fraction: belowFloor ? 0 : ddcFraction, ramp: ramp)

    if !wroteOK {
      // DDC not accepted on this display — follow the built-in via gamma. This is
      // the only way to dim a monitor that doesn't speak DDC, so trade backlight
      // control for a software luminance scale. Only possible (and only reported
      // as working) when we resolved a CoreGraphics display id to drive.
      if display.cgDisplayID != nil {
        let level = max(minGamma, dimInput)
        gamma.set(display.cgDisplayID, factor: level)
        display.markGammaFollow(level: level)
      } else {
        display.clearGammaFollow() // no DDC and no gamma path — genuinely unreachable
      }
      return
    }
    display.clearGammaFollow()
    if belowFloor {
      // Below the floor, hold DDC at minimum and dim via gamma. Normally clamped
      // to a small visible floor; full blackout removes the clamp so it reaches 0.
      gamma.set(display.cgDisplayID, factor: max(minGamma, dimInput / floor))
    } else {
      gamma.set(display.cgDisplayID, factor: 1)
    }
  }

  // Normal sync: input is the built-in level mapped through the monitor's curve.
  private func applyToDisplay(_ display: ExternalDisplay, builtin: Double, ramp: Bool) {
    setLevel(display, ddcFraction: display.curve.external(for: builtin),
             dimInput: builtin, floor: display.curve.zeroBuiltin, ramp: ramp)
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

  /// Apply per-display color corrections keyed by ExternalDisplay.id. Runs on the
  /// serial queue; missing ids reset to identity. Safe after reconnect/wake.
  func applyColorCorrections(_ map: [String: ColorCorrection]) {
    queue.async {
      for display in self.externals {
        guard let cg = display.cgDisplayID else { continue }
        self.gamma.setCorrection(cg, map[display.id] ?? .identity)
      }
    }
  }

  private func reportMonitors() {
    let states = externals.map {
      MonitorState(id: $0.id, name: $0.name,
                   enabled: !disabledIDs.contains($0.id),
                   healthy: $0.lastWriteOK || $0.followsViaGamma, // gamma fallback still tracks
                   brightness: $0.currentFraction)
    }
    DispatchQueue.main.async { self.onMonitors?(states) }
  }

  /// Thread-safe snapshot of current externals for UI (id, cgDisplayID, name).
  func snapshotExternals() -> [(id: String, cg: CGDirectDisplayID?, name: String)] {
    queue.sync { externals.map { ($0.id, $0.cgDisplayID, $0.name) } }
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
