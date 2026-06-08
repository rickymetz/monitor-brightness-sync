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
    sync.start()

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
