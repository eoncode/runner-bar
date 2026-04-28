import ServiceManagement

/// Manages the app's launch-at-login registration via `SMAppService`.
enum LoginItem {
    /// `true` when the app is registered to launch at login.
    /// Checks the live `SMAppService` status — reflects changes made
    /// outside the app (e.g. via System Settings > General > Login Items).
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggles launch-at-login on or off.
    /// Registers the app if currently unregistered; unregisters it if registered.
    /// Errors are logged to stderr but otherwise swallowed — failure is non-fatal
    /// since the checkbox UI will simply reflect the unchanged state on next read.
    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("[RunnerBar] LoginItem toggle failed: \(error)")
        }
    }
}
