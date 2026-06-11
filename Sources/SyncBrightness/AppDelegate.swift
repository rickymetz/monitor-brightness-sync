import Carbon // Apple Event constants for login-item launch detection
import Cocoa
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private let toggleItem = NSMenuItem(title: "Sync external brightness", action: #selector(toggleSync), keyEquivalent: "")
  private let dimmingItem = NSMenuItem(title: "Allow extra-dark dimming", action: #selector(toggleDimming), keyEquivalent: "")
  private let blackoutItem = NSMenuItem(title: "Allow dimming all the way to black", action: #selector(toggleBlackout), keyEquivalent: "")
  private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
  private let keyControlItem = NSMenuItem(title: "Use brightness keys with lid closed", action: #selector(enableKeyControl), keyEquivalent: "")
  private let monitorsMenu = NSMenu()

  private let sync = SyncController()
  private let mediaKeyTap = MediaKeyTap()
  private let hotKeyUp = HotKey()
  private let hotKeyDown = HotKey()
  private let hud = BrightnessHUD()
  private let messageHUD = MessageHUD()
  private var allOffKeyPresses = 0
  private var calibrationController: CalibrationWindowController?
  private var onboardingController: OnboardingWindowController?
  private var controlWindowController: ControlWindowController?
  private var colorSyncWC: ColorSyncWindowController?
  private var controlVisible = false
  private var calibrationVisible = false
  private var isCalibrating = false

  private var monitors: [MonitorState] = []
  private var externalOnlyLevel: Double?
  private var axPollTimer: Timer?
  private var axPollElapsed = 0

  // Last status values reported by the sync controller.
  private var lastFraction = -1.0
  private var lastExternalCount = 0
  private var hasSynced = false

  // MARK: - Persisted settings

  private let enabledKey = "syncEnabled"
  private var isEnabled: Bool {
    get { UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  private let dimmingKey = "subFloorDimming"
  private var subFloorDimming: Bool {
    get { UserDefaults.standard.object(forKey: dimmingKey) == nil ? true : UserDefaults.standard.bool(forKey: dimmingKey) }
    set { UserDefaults.standard.set(newValue, forKey: dimmingKey) }
  }

  private let keyControlKey = "keyControlEnabled"
  private var keyControlEnabled: Bool { // opt-in; defaults to off (needs Accessibility)
    get { UserDefaults.standard.bool(forKey: keyControlKey) }
    set { UserDefaults.standard.set(newValue, forKey: keyControlKey) }
  }

  private let blackoutKey = "allowBlackout"
  private var allowBlackout: Bool { // opt-in; defaults to off
    get { UserDefaults.standard.bool(forKey: blackoutKey) }
    set { UserDefaults.standard.set(newValue, forKey: blackoutKey) }
  }

  private let profilesKey = "profiles"
  private var profiles: [String: BrightnessCurve] = [:]

  private let colorProfilesKey = "colorCorrectionProfiles"
  private let colorSyncEnabledKey = "colorSyncEnabled"
  private var colorCorrections: [String: ColorCorrection] = [:]

  // 3×3 (ICC) path: the saved measurements drive a per-display ICC profile. ColorSync
  // keeps an installed profile across launches, so this is a persistent calibration —
  // we re-assert it on launch and restore factory on reset/disable.
  private let colorMeasurementKey = "colorSyncMeasurement"
  private var colorMeasurement: ColorSyncMeasurement?

  private func loadColorMeasurement() -> ColorSyncMeasurement? {
    guard let data = UserDefaults.standard.data(forKey: colorMeasurementKey) else { return nil }
    return try? JSONDecoder().decode(ColorSyncMeasurement.self, from: data)
  }

  /// Install the ICC profiles when enabled and we have a measurement; otherwise revert
  /// every corrected display to factory. The single funnel for the 3×3 color path.
  private func applyColorProfiles() {
    if colorSyncEnabled, let m = colorMeasurement {
      sync.applyColorProfiles(samples: m.samples, referenceID: m.referenceID)
    } else {
      sync.clearColorProfiles()
    }
  }

  /// Persist a fresh measurement and install its ICC profiles (called from Save).
  private func saveColorMeasurement(_ m: ColorSyncMeasurement) {
    colorMeasurement = m
    if let data = try? JSONEncoder().encode(m) {
      UserDefaults.standard.set(data, forKey: colorMeasurementKey)
    }
    // The 3×3 ICC profile supersedes the diagonal gamma-table color path; clear any
    // old diagonal corrections so the two can't compound on the externals.
    colorCorrections = [:]
    UserDefaults.standard.removeObject(forKey: colorProfilesKey)
    colorSyncEnabled = true
    sync.applyColorCorrections(effectiveColorCorrections)   // identity → clean gamma table
    applyColorProfiles()
    controlWindowController?.setColorSyncSummary(colorSyncSummaryText())
  }

  private var colorSyncEnabled: Bool {
    get { UserDefaults.standard.object(forKey: colorSyncEnabledKey) == nil ? true
                                                                            : UserDefaults.standard.bool(forKey: colorSyncEnabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: colorSyncEnabledKey) }
  }

  private let matchGammaKey = "colorSyncMatchGamma"
  /// Apply the per-display gamma term. Off by default — it can wash out mid-tones;
  /// white-point matching is the dependable part.
  private var matchGamma: Bool {
    get { UserDefaults.standard.bool(forKey: matchGammaKey) }   // default false
    set { UserDefaults.standard.set(newValue, forKey: matchGammaKey) }
  }

  /// What's actually applied: nothing when disabled; otherwise the saved
  /// corrections, with the gamma term stripped unless gamma matching is on.
  private var effectiveColorCorrections: [String: ColorCorrection] {
    guard colorSyncEnabled else { return [:] }
    if matchGamma { return colorCorrections }
    return colorCorrections.mapValues {
      ColorCorrection(redGain: $0.redGain, greenGain: $0.greenGain, blueGain: $0.blueGain, gamma: 1)
    }
  }

  private func setMatchGamma(_ on: Bool) {
    matchGamma = on
    sync.applyColorCorrections(effectiveColorCorrections)
  }

  private func loadColorCorrections() -> [String: ColorCorrection] {
    guard let data = UserDefaults.standard.data(forKey: colorProfilesKey),
          let decoded = try? JSONDecoder().decode([String: ColorCorrection].self, from: data)
    else { return [:] }
    return decoded
  }

  private func saveColorCorrections(_ map: [String: ColorCorrection]) {
    colorCorrections = map
    if let data = try? JSONEncoder().encode(map) {
      UserDefaults.standard.set(data, forKey: colorProfilesKey)
    }
    colorSyncEnabled = true   // a fresh save implies "apply it"
    sync.applyColorCorrections(effectiveColorCorrections)
    controlWindowController?.setColorSyncSummary(colorSyncSummaryText())
  }

  /// Live toggle: apply the saved correction or revert to identity (for A/B).
  private func setColorSyncEnabled(_ on: Bool) {
    colorSyncEnabled = on
    sync.applyColorCorrections(effectiveColorCorrections)
    applyColorProfiles()   // install/restore the 3×3 ICC profiles to match
  }

  /// Clear the saved correction entirely and revert the displays.
  private func resetColorSync() {
    colorCorrections = [:]
    colorMeasurement = nil
    UserDefaults.standard.removeObject(forKey: colorProfilesKey)
    UserDefaults.standard.removeObject(forKey: colorMeasurementKey)
    sync.applyColorCorrections([:])
    sync.clearColorProfiles()   // revert displays to factory ICC profiles
    controlWindowController?.setColorSyncSummary(colorSyncSummaryText())
  }

  /// Human-readable summary of the saved correction, for the settings window.
  private func colorSyncSummaryText() -> String {
    guard let m = colorMeasurement, !m.samples.isEmpty else { return "No color corrections saved yet." }
    var names: [String: String] = ["builtin": "Built-in"]
    for e in sync.snapshotExternals() { names[e.id] = e.name }
    let corrected = m.samples.keys.filter { $0 != m.referenceID }.sorted()
    let list = corrected.map { names[$0] ?? $0 }.joined(separator: ", ")
    let anchor = names[m.referenceID] ?? m.referenceID
    return "3×3 color match (ICC) active.\nAnchored on \(anchor); corrected: \(list.isEmpty ? "—" : list)."
  }

  private let disabledKey = "disabledMonitors"
  private var disabledIDs: Set<String> = []

  private let onboardedKey = "hasOnboarded"

  private let hotkeysEnabledKey = "hotkeysEnabled"
  private var hotkeysEnabled: Bool { // opt-in; defaults off so we don't grab keys uninvited
    get { UserDefaults.standard.bool(forKey: hotkeysEnabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: hotkeysEnabledKey) }
  }
  private let hotkeyUpKey = "hotkeyUp"
  private let hotkeyDownKey = "hotkeyDown"
  private var hotkeyUp = KeyCombo.defaultUp
  private var hotkeyDown = KeyCombo.defaultDown

  // MARK: - Launch

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Self-heal: if a previous run was force-killed while a display was gamma-
    // dimmed, clear leftover dimming so a stuck-dark screen recovers on launch.
    CGDisplayRestoreColorSyncSettings()

    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let icon = NSImage(contentsOf: iconURL) {
      NSApp.applicationIconImage = icon
    }
    profiles = loadProfiles()
    colorCorrections = loadColorCorrections()
    colorMeasurement = loadColorMeasurement()
    disabledIDs = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    hotkeyUp = loadCombo(hotkeyUpKey) ?? .defaultUp
    hotkeyDown = loadCombo(hotkeyDownKey) ?? .defaultDown
    hotKeyUp.onPress = { [weak self] in self?.handleHotKey(increase: true) }
    hotKeyDown.onPress = { [weak self] in self?.handleHotKey(increase: false) }

    buildStatusItem()

    sync.onUpdate = { [weak self] fraction, externalCount in
      guard let self else { return }
      self.hasSynced = true
      self.lastFraction = fraction
      self.lastExternalCount = externalCount
      self.renderStatus()
    }
    sync.onMonitors = { [weak self] monitors in
      guard let self else { return }
      self.monitors = monitors
      self.controlWindowController?.updateMonitors(monitors)
      self.renderStatus()
      self.sync.applyColorCorrections(self.effectiveColorCorrections)
      // A monitor was (un)plugged while the Color Sync window is open — refresh its
      // display list so a just-connected display (e.g. the Dell) is included.
      self.colorSyncWC?.refreshDisplays(self.buildColorSyncDisplayList())
    }
    sync.onExternalChangedExternally = { [weak self] _ in
      // The monitor's brightness moved outside the app (its own buttons): drop
      // the cached clamshell base so the next key press steps from the new value.
      self?.externalOnlyLevel = nil
    }

    sync.setEnabled(isEnabled)
    sync.setSubFloorDimming(subFloorDimming)
    sync.setAllowBlackout(allowBlackout)
    sync.setDisabled(disabledIDs)
    sync.setProfiles(profiles)
    sync.applyColorCorrections(effectiveColorCorrections)
    sync.start()
    applyColorProfiles()   // re-assert the saved 3×3 ICC calibration after displays enumerate

    setupWakeObservers()
    setupMediaKeyTap()
    applyHotkeys()
    pushToggleStates()
    renderStatus()
    // Don't pop the window when macOS launches us at login — just live in the
    // menu bar. Manual launches (and first-run onboarding) still open it.
    if !launchedAsLoginItem() { showOnboardingOrControl() }
  }

  /// True when macOS launched us as a login item rather than the user opening the
  /// app, detected via the open-application Apple Event's login-item flag.
  private func launchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
          event.eventID == kAEOpenApplication else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }

  func applicationWillTerminate(_ notification: Notification) {
    sync.shutdown() // restore gamma
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showControlWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  // MARK: - Status item / menu

  private func buildStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.isVisible = true
    if let button = statusItem.button {
      if let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness sync") {
        image.isTemplate = true
        button.image = image
      } else {
        button.title = "☀"
      }
      button.toolTip = "Monitor Brightness Sync"
    }

    let menu = NSMenu()
    statusMenuItem.isEnabled = false
    statusMenuItem.toolTip = "The built-in brightness currently being mirrored to your external monitors."
    menu.addItem(statusMenuItem)

    // Full settings live in the control window; the menu is a quick subset.
    menu.addItem(.separator())
    let openSettingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
    openSettingsItem.target = self
    openSettingsItem.toolTip = "Open the full settings window (Displays, Dimming, Shortcuts, General)."
    menu.addItem(openSettingsItem)

    // Behavior toggles
    menu.addItem(.separator())
    toggleItem.target = self
    toggleItem.toolTip = "Mirror the built-in display's brightness onto your external monitors."
    menu.addItem(toggleItem)
    dimmingItem.target = self
    dimmingItem.toolTip = "Dims the external below its hardware minimum (in software) so it can match the Mac's darkness at low brightness."
    menu.addItem(dimmingItem)
    blackoutItem.target = self
    blackoutItem.toolTip = "At the lowest brightness, let the external go completely black, like the Mac display. Turns on extra-dark dimming."
    menu.addItem(blackoutItem)
    keyControlItem.target = self
    keyControlItem.toolTip = "When the lid is closed, the brightness keys adjust the external monitor (needs Accessibility permission)."
    menu.addItem(keyControlItem)

    // Displays & calibration
    menu.addItem(.separator())
    let monitorsItem = NSMenuItem(title: "Monitors", action: nil, keyEquivalent: "")
    monitorsItem.toolTip = "Turn each external display's sync on or off, or set its brightness manually."
    monitorsMenu.delegate = self
    monitorsItem.submenu = monitorsMenu
    menu.addItem(monitorsItem)
    let calibrateItem = NSMenuItem(title: "Calibrate…", action: #selector(openCalibration), keyEquivalent: "")
    calibrateItem.target = self
    calibrateItem.toolTip = "Match each external monitor to the built-in by eye at several brightness levels."
    menu.addItem(calibrateItem)
    let resetItem = NSMenuItem(title: "Reset calibration", action: #selector(resetCalibration), keyEquivalent: "")
    resetItem.target = self
    resetItem.toolTip = "Reset the connected monitor(s) calibration to the default."
    menu.addItem(resetItem)

    // App
    menu.addItem(.separator())
    loginItem.target = self
    loginItem.toolTip = "Open Monitor Brightness Sync automatically when you log in."
    menu.addItem(loginItem)
    let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.toolTip = "Quit Monitor Brightness Sync."
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  // MARK: - Wake handling

  private func setupWakeObservers() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
  }

  @objc private func systemDidWake() {
    externalOnlyLevel = nil // re-seed from the monitor's real brightness after wake
    sync.wake()
  }

  // MARK: - External-only key control (clamshell)

  private func setupMediaKeyTap() {
    mediaKeyTap.onBrightnessKey = { [weak self] increase, isKeyDown in
      guard let self else { return false }
      // Only act in clamshell (no built-in); otherwise let the key pass through
      // so macOS keeps driving the built-in and our sync mirrors it.
      guard BuiltinBrightness.builtinDisplayID() == nil else { return false }
      guard !self.monitors.isEmpty else { return false } // nothing connected — pass through
      if isKeyDown { self.adjustExternalOnly(increase: increase) }
      return true // swallow the key in clamshell mode
    }
    // Only resume the tap on launch if the user previously enabled it.
    if keyControlEnabled, MediaKeyTap.accessibilityGranted(prompt: false) {
      mediaKeyTap.start()
    }
  }

  /// Adjust the external(s) directly by one step (clamshell / external-only).
  /// Shared by the brightness-key tap and the custom hotkeys.
  @discardableResult
  private func adjustExternalOnly(increase: Bool) -> Bool {
    let controllable = monitors.filter { $0.enabled }
    guard let target = controllable.first else {
      // Clamshell, but every external is turned off in the app.
      guard !monitors.isEmpty else { return false }
      allOffKeyPresses += 1
      if allOffKeyPresses >= 2 { // hint once they're clearly trying
        messageHUD.show("Turn on a monitor to use the brightness keys")
      }
      return true
    }
    allOffKeyPresses = 0
    let step = 1.0 / 16.0
    let base = externalOnlyLevel ?? target.brightness
    let level = max(0, min(1, base + (increase ? step : -step)))
    externalOnlyLevel = level
    sync.applyExternalOnly(level: level)
    hud.show(level: level, name: target.name)
    return true
  }

  // MARK: - Custom global hotkeys

  /// Custom hotkeys replace the brightness keys: with the lid open they nudge the
  /// built-in (the sync loop mirrors it to externals); in clamshell they drive
  /// the external directly. Carbon hotkeys are system-wide and need no grant.
  private func handleHotKey(increase: Bool) {
    if let builtinID = BuiltinBrightness.builtinDisplayID() {
      guard let current = BuiltinBrightness.fraction(of: builtinID) else { return }
      let step = 1.0 / 16.0
      let level = max(0, min(1, current + (increase ? step : -step)))
      BuiltinBrightness.setFraction(level, of: builtinID)
      hud.show(level: level, name: "Built-in Display")
    } else {
      adjustExternalOnly(increase: increase)
    }
  }

  private func applyHotkeys() {
    guard hotkeysEnabled else {
      hotKeyUp.unregister(); hotKeyDown.unregister()
      return
    }
    let okUp = hotKeyUp.register(hotkeyUp)
    let okDown = hotKeyDown.register(hotkeyDown)
    if !okUp || !okDown {
      messageHUD.show("Couldn't register a shortcut — it may already be in use")
    }
  }

  private func setHotkeysEnabled(_ on: Bool) {
    hotkeysEnabled = on
    applyHotkeys()
    pushToggleStates()
  }

  private func setHotkey(up: Bool, combo: KeyCombo?) {
    if up { hotkeyUp = combo ?? .defaultUp; saveCombo(hotkeyUp, hotkeyUpKey) }
    else { hotkeyDown = combo ?? .defaultDown; saveCombo(hotkeyDown, hotkeyDownKey) }
    applyHotkeys()
    pushToggleStates()
  }

  private func loadCombo(_ key: String) -> KeyCombo? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(KeyCombo.self, from: data)
  }

  private func saveCombo(_ combo: KeyCombo, _ key: String) {
    if let data = try? JSONEncoder().encode(combo) { UserDefaults.standard.set(data, forKey: key) }
  }


  private func updateKeyControlItem() {
    keyControlItem.state = mediaKeyTap.isRunning ? .on : .off // checkmark reflects on/off
  }

  // MARK: - Windows

  /// On first launch, welcome the user; afterwards go straight to the controls.
  private func showOnboardingOrControl() {
    guard !UserDefaults.standard.bool(forKey: onboardedKey) else {
      showControlWindow()
      return
    }
    let key = onboardedKey
    let controller = OnboardingWindowController()
    controller.onFinished = { [weak self] in
      UserDefaults.standard.set(true, forKey: key)
      self?.onboardingController = nil
      self?.showControlWindow()
    }
    onboardingController = controller
    NSApp.setActivationPolicy(.regular) // a visible window needs a non-accessory policy
    controller.show()
  }

  private func showControlWindow() {
    if controlWindowController == nil {
      let controller = ControlWindowController()
      controller.onSetSync = { [weak self] enabled in self?.setSyncEnabled(enabled) }
      controller.onSetDimming = { [weak self] on in self?.setDimming(on) }
      controller.onSetBlackout = { [weak self] on in self?.setBlackout(on) }
      controller.onSetLoginItem = { [weak self] on in self?.setLoginItem(on) }
      controller.onSetKeyControl = { [weak self] on in self?.setKeyControl(on) }
      controller.onCalibrate = { [weak self] in self?.openCalibration() }
      controller.onReset = { [weak self] in self?.resetCalibration() }
      controller.onColorSync = { [weak self] in self?.openColorSync() }
      controller.onSetColorSyncEnabled = { [weak self] on in self?.setColorSyncEnabled(on) }
      controller.onSetMatchGamma = { [weak self] on in self?.setMatchGamma(on) }
      controller.onResetColorSync = { [weak self] in self?.resetColorSync() }
      controller.onToggleTestField = { [weak self] in self?.toggleTestField() }
      controller.onSetMonitorEnabled = { [weak self] id, enabled in self?.setMonitorEnabled(id, enabled) }
      controller.onSetMonitorBrightness = { [weak self] id, fraction in self?.sync.setManual(id: id, fraction: fraction) }
      controller.onSetHotkeysEnabled = { [weak self] on in self?.setHotkeysEnabled(on) }
      controller.onSetHotkeyUp = { [weak self] combo in self?.setHotkey(up: true, combo: combo) }
      controller.onSetHotkeyDown = { [weak self] combo in self?.setHotkey(up: false, combo: combo) }
      controller.onClose = { [weak self] in
        self?.controlVisible = false
        self?.updateActivationPolicy()
      }
      controlWindowController = controller
    }
    controlVisible = true
    updateActivationPolicy()
    controlWindowController?.colorSyncEnabled = colorSyncEnabled
    controlWindowController?.matchGamma = matchGamma
    controlWindowController?.colorSyncSummary = colorSyncSummaryText()
    controlWindowController?.updateMonitors(monitors)
    controlWindowController?.show()
    pushToggleStates()
    renderStatus()
  }

  private func updateActivationPolicy() {
    NSApp.setActivationPolicy(controlVisible || calibrationVisible ? .regular : .accessory)
  }

  // MARK: - Per-monitor enable

  private func setMonitorEnabled(_ id: String, _ enabled: Bool) {
    if enabled { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
    UserDefaults.standard.set(Array(disabledIDs), forKey: disabledKey)
    sync.setDisabled(disabledIDs)
  }

  // MARK: - Monitors submenu (built fresh each time it opens)

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === monitorsMenu else { return }
    monitorsMenu.removeAllItems()
    guard !monitors.isEmpty else {
      let item = NSMenuItem(title: "No external display connected", action: nil, keyEquivalent: "")
      item.isEnabled = false
      monitorsMenu.addItem(item)
      return
    }
    for monitor in monitors {
      let check = NSMenuItem(title: monitor.healthy ? monitor.name : "⚠ \(monitor.name)",
                             action: #selector(menuMonitorToggle(_:)), keyEquivalent: "")
      check.target = self
      check.state = monitor.enabled ? .on : .off
      check.representedObject = monitor.id
      check.toolTip = monitor.healthy
        ? "Include \(monitor.name) in brightness sync."
        : "\(monitor.name) isn't responding to DDC — check that DDC/CI is enabled in its menu."
      monitorsMenu.addItem(check)

      let sliderItem = NSMenuItem()
      sliderItem.view = makeMenuSliderView(id: monitor.id, value: monitor.brightness, name: monitor.name)
      monitorsMenu.addItem(sliderItem)
    }
  }

  private func makeMenuSliderView(id: String, value: Double, name: String) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
    let slider = NSSlider(value: value * 100, minValue: 0, maxValue: 100,
                          target: self, action: #selector(menuMonitorSlider(_:)))
    slider.isContinuous = true
    slider.identifier = NSUserInterfaceItemIdentifier(id)
    slider.toolTip = "Set \(name)'s brightness manually."
    slider.frame = NSRect(x: 24, y: 3, width: 196, height: 20)
    view.addSubview(slider)
    return view
  }

  @objc private func menuMonitorToggle(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    let enabled = sender.state != .on
    sender.state = enabled ? .on : .off
    setMonitorEnabled(id, enabled)
  }

  @objc private func menuMonitorSlider(_ sender: NSSlider) {
    guard let id = sender.identifier?.rawValue else { return }
    sync.setManual(id: id, fraction: sender.doubleValue / 100)
  }

  // MARK: - Calibration

  @objc private func openSettings() { showControlWindow() }

  func openColorSync() {
    guard colorSyncWC == nil else { colorSyncWC?.showWindow(nil); return }
    let wc = ColorSyncWindowController()
    wc.displays = buildColorSyncDisplayList()
    wc.onPreview = { [weak self] map in self?.sync.applyColorCorrections(map, viaHardware: false) }  // live, gamma-only, no persist
    wc.onSave = { [weak self] map in self?.saveColorCorrections(map) }           // persist + apply
    // 3×3 (ICC) path: install from the just-measured samples (preview), or persist+install (save).
    wc.onApplyProfiles = { [weak self] samples, refID in
      self?.sync.applyColorProfiles(samples: samples, referenceID: refID)
    }
    wc.onSaveProfiles = { [weak self] samples, refID in
      self?.saveColorMeasurement(ColorSyncMeasurement(referenceID: refID, samples: samples))
    }
    wc.onClearProfiles = { [weak self] in self?.sync.clearColorProfiles() }   // "Before" A/B
    wc.onShowTestField = { [weak self] in self?.showTestField() }
    wc.onHideTestField = { [weak self] in self?.hideTestField() }
    wc.onClose = { [weak self] in
      guard let self else { return }
      self.colorSyncWC = nil
      self.hideTestField()
      // Restore brightness + resume sync, and revert displays to the saved state
      // (discarding any unsaved preview).
      self.sync.endFixedBrightness()
      self.sync.applyColorCorrections(self.effectiveColorCorrections)
      self.applyColorProfiles()   // back to the saved ICC calibration (or factory)
    }
    // Measure the displays uncorrected: clear the gamma-table correction AND revert any
    // installed ICC profile so the camera sees each panel's native color. Cancelling
    // restores the saved state via onClose.
    sync.applyColorCorrections([:])
    sync.clearColorProfiles()
    // Hold every display at a known, clip-safe brightness (50%) so each is
    // measured at the same backlight operating point. Restored in onClose.
    sync.beginFixedBrightness(0.5)
    wc.begin()
    colorSyncWC = wc
  }

  // MARK: - Side-by-side test field (debug)

  private var testFieldWindows: [NSWindow] = []

  /// Toggle a uniform mid-gray field on every display, so the iOS side-by-side
  /// check has a clean target. The displayed field passes through the gamma
  /// correction, so toggling "Apply color sync correction" lets you A/B it.
  /// Dismiss by clicking anywhere on it or pressing Escape (it covers the
  /// Settings window, so the toggle button isn't reachable while it's up).
  private func toggleTestField() {
    if testFieldWindows.isEmpty { showTestField() } else { hideTestField() }
  }

  private func showTestField() {
    guard testFieldWindows.isEmpty else { return }   // already showing
    for (i, screen) in NSScreen.screens.enumerated() {
      let w = TestFieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.level = .screenSaver
      w.isOpaque = true
      w.onDismiss = { [weak self] in self?.hideTestField() }
      let view = TestFieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.label = String(UnicodeScalar(UInt8(65 + min(i, 25))))   // A, B, C…
      view.onDismiss = { [weak self] in self?.hideTestField() }
      w.contentView = view
      w.setFrame(screen.frame, display: true)
      w.makeKeyAndOrderFront(nil)
      testFieldWindows.append(w)
    }
    NSApp.activate(ignoringOtherApps: true)   // so Escape reaches the key window
  }

  private func hideTestField() {
    testFieldWindows.forEach { $0.orderOut(nil) }
    testFieldWindows.removeAll()
  }

  /// Built-in first (reference), then externals; pair each NSScreen to a display id.
  private func buildColorSyncDisplayList() -> [(id: String, screen: NSScreen, label: String)] {
    let exts = sync.snapshotExternals()
    var out: [(id: String, screen: NSScreen, label: String)] = []
    for screen in NSScreen.screens {
      guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let cg = CGDirectDisplayID(num.uint32Value)
      if CGDisplayIsBuiltin(cg) != 0 {
        out.insert((id: "builtin", screen: screen, label: "Built-in"), at: 0)
      } else if let ext = exts.first(where: { $0.cg == cg }) {
        out.append((id: ext.id, screen: screen, label: ext.name))
      }
    }
    return out
  }

  @objc private func openCalibration() {
    guard calibrationController == nil else { return }
    let displays = monitors.map { DisplayInfo(id: $0.id, name: $0.name) }
    sync.setCalibrating(true, targetID: displays.first?.id)
    calibrationVisible = true
    isCalibrating = true
    updateActivationPolicy()
    renderStatus()

    let controller = CalibrationWindowController(
      displays: displays,
      savedCurves: profiles,
      onSelectTarget: { [weak self] id in self?.sync.setCalibrating(true, targetID: id) },
      onManualExternal: { [weak self] fraction in self?.sync.setManualExternal(fraction) },
      onCommit: { [weak self] curves in
        guard let self else { return }
        for (id, curve) in curves { self.profiles[id] = curve }
        self.saveProfiles(self.profiles)
        self.sync.setProfiles(self.profiles)
        self.sync.setCalibrating(false)
        self.calibrationController = nil
        self.calibrationVisible = false
        self.isCalibrating = false
        self.updateActivationPolicy()
        self.renderStatus()
      }
    )
    calibrationController = controller
    controller.show()
  }

  @objc private func resetCalibration() {
    for monitor in monitors { profiles[monitor.id] = .default }
    saveProfiles(profiles)
    sync.setProfiles(profiles)
  }

  private func loadProfiles() -> [String: BrightnessCurve] {
    guard let data = UserDefaults.standard.data(forKey: profilesKey),
          let decoded = try? JSONDecoder().decode([String: BrightnessCurve].self, from: data)
    else { return [:] }
    return decoded
  }

  private func saveProfiles(_ profiles: [String: BrightnessCurve]) {
    if let data = try? JSONEncoder().encode(profiles) {
      UserDefaults.standard.set(data, forKey: profilesKey)
    }
  }

  // MARK: - Toggles

  @objc private func toggleSync() { setSyncEnabled(!isEnabled) }
  @objc private func toggleDimming() { setDimming(!subFloorDimming) }
  @objc private func toggleBlackout() { setBlackout(!allowBlackout) }
  @objc private func toggleLoginItem() { setLoginItem(!LoginItem.isEnabled) }
  @objc private func enableKeyControl() { setKeyControl(!mediaKeyTap.isRunning) }

  private func startAccessibilityPolling() {
    axPollTimer?.invalidate()
    axPollElapsed = 0
    // Once the user flips the Accessibility switch, start the tap automatically
    // instead of making them click the menu item again.
    axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
      guard let self else { timer.invalidate(); return }
      self.axPollElapsed += 1
      if self.mediaKeyTap.start() {
        timer.invalidate(); self.axPollTimer = nil
        self.pushToggleStates()
      } else if self.axPollElapsed >= 120 {
        timer.invalidate(); self.axPollTimer = nil // give up; relaunch will pick it up
      }
    }
  }

  private func stopAccessibilityPolling() {
    axPollTimer?.invalidate()
    axPollTimer = nil
  }

  private func setSyncEnabled(_ enabled: Bool) {
    isEnabled = enabled
    sync.setEnabled(enabled)
    renderStatus() // renderStatus pushes syncOn to the window
    pushToggleStates()
  }

  private func setDimming(_ on: Bool) {
    subFloorDimming = on
    sync.setSubFloorDimming(on)
    pushToggleStates()
  }

  private func setBlackout(_ on: Bool) {
    allowBlackout = on
    sync.setAllowBlackout(on)
    if on, !subFloorDimming { setDimming(true) } // blackout needs the dimming machinery
    pushToggleStates()
  }

  private func setLoginItem(_ on: Bool) {
    LoginItem.setEnabled(on)
    pushToggleStates()
  }

  private func setKeyControl(_ on: Bool) {
    keyControlEnabled = on
    if on {
      if mediaKeyTap.start() {
        // Already trusted — tap is live.
      } else {
        // Not trusted yet: open the Accessibility prompt once, then watch for the
        // grant so we can start without the user clicking again.
        _ = MediaKeyTap.accessibilityGranted(prompt: true)
        startAccessibilityPolling()
      }
    } else {
      stopAccessibilityPolling()
      mediaKeyTap.stop()
    }
    pushToggleStates()
  }

  /// Reflect global toggle state in both the menu and the control window.
  private func pushToggleStates() {
    toggleItem.state = isEnabled ? .on : .off
    dimmingItem.state = subFloorDimming ? .on : .off
    blackoutItem.state = allowBlackout ? .on : .off
    loginItem.state = LoginItem.isEnabled ? .on : .off
    updateKeyControlItem()
    controlWindowController?.updateToggles(dimming: subFloorDimming,
                                           blackout: allowBlackout,
                                           login: LoginItem.isEnabled,
                                           keyControl: mediaKeyTap.isRunning)
    controlWindowController?.updateHotkeys(enabled: hotkeysEnabled, up: hotkeyUp, down: hotkeyDown)
  }

  // MARK: - Status

  private func renderStatus() {
    let unhealthy = monitors.first { $0.enabled && !$0.healthy }
    let title: String
    let badge: String
    if isCalibrating {
      title = "Calibrating…"; badge = " cal"
    } else if !hasSynced {
      title = "Starting…"; badge = ""
    } else if lastExternalCount == 0 {
      title = "No external display connected"; badge = " --"
    } else if let bad = unhealthy {
      title = "⚠ \(bad.name) not responding"; badge = " ⚠"
    } else if !isEnabled {
      title = "Sync paused"; badge = " off"
    } else if lastFraction < 0 {
      title = "Syncing…"; badge = ""
    } else {
      title = String(format: "Built-in brightness: %d%%", Int((lastFraction * 100).rounded()))
      badge = String(format: " %d%%", Int((lastFraction * 100).rounded()))
    }

    statusMenuItem.title = title
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    statusItem.button?.attributedTitle = NSAttributedString(string: badge, attributes: [.font: font])
    statusItem.button?.setAccessibilityLabel("Monitor Brightness Sync — \(title)") // VoiceOver reads status, not the badge glyphs
    controlWindowController?.update(statusText: title, syncOn: isEnabled)
  }
}

/// Fullscreen test-field window that dismisses on Escape (it can become key so it
/// receives the keystroke).
private final class TestFieldWindow: NSWindow {
  var onDismiss: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { onDismiss?() }   // Escape
}

/// Mid-gray fill with a corner label (A/B/…) that dismisses on a click anywhere.
/// The label sits in the corners so the center stays a clean field to sample.
private final class TestFieldView: NSView {
  var onDismiss: (() -> Void)?
  var label = ""
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) { onDismiss?() }

  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 0.5, alpha: 1).setFill(); bounds.fill()
    guard !label.isEmpty else { return }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.boldSystemFont(ofSize: 120),
      .foregroundColor: NSColor(white: 0.25, alpha: 1),
    ]
    let s = label as NSString
    let size = s.size(withAttributes: attrs)
    let inset: CGFloat = 60
    // Draw in all four corners so it's visible however the phone is angled.
    for p in [NSPoint(x: inset, y: inset),
              NSPoint(x: bounds.maxX - size.width - inset, y: inset),
              NSPoint(x: inset, y: bounds.maxY - size.height - inset),
              NSPoint(x: bounds.maxX - size.width - inset, y: bounds.maxY - size.height - inset)] {
      s.draw(at: p, withAttributes: attrs)
    }
  }
}
