import ServiceManagement

/// Thin wrapper over SMAppService for the "Launch at login" toggle.
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Returns the resulting enabled state (unchanged on failure).
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      NSLog("LoginItem: failed to \(enabled ? "register" : "unregister"): \(error)")
    }
    return isEnabled
  }
}
