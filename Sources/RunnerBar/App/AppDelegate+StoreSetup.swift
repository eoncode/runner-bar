// AppDelegate+StoreSetup.swift
// RunnerBar

import AppKit

/// AppDelegate extension wiring app-lifecycle callbacks to store and service setup.
extension AppDelegate {

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    /// - Parameter _: The notification (unused).
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Configures the GitHub API clients, builds the
    /// status-bar item, and constructs the NSPopover panel.
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")
        configureGHToken { githubToken() }
        configureGHAPI { endpoint in await ghAPI(endpoint) }
        configureGHRaw { endpoint in await urlSessionRaw(endpoint) }
        // Both `endpoint` and `timeout` must be forwarded so callers that pass
        // a custom timeout via ghAPIPaginated(endpoint, timeout:) are not silently
        // overridden by urlSessionAPIPaginated’s 60s default.
        configureGHAPIPaginated { endpoint, timeout in
            await urlSessionAPIPaginated(endpoint, timeout: timeout)
        }
        setupStatusItem()
        setupPanel()
        setupSignOutSubscription()
    }
}
