// AppDelegate+StoreSetup.swift
// RunnerBar

import AppKit
import RunnerBarCore

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
    /// status-bar item, constructs the NSPopover panel, and migrates per-scope
    /// preferences from the legacy flat-key format to the single-blob actor (#1538).
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")
        configureGHToken { githubToken() }
        // Wire all three shim transports directly to sharedGitHubTransport,
        // eliminating the intermediate hop through module-level free-function shims.
        // The token is resolved per-call via sharedGitHubTransport's default
        // tokenProvider (githubTokenCore()), which reads the box configured above.
        configureGHAPI { endpoint in
            await sharedGitHubTransport.apiAsync(endpoint)
        }
        configureGHRaw { endpoint in
            await sharedGitHubTransport.raw(endpoint)
        }
        // Both `endpoint` and `timeout` must be forwarded so callers that pass
        // a custom timeout via ghAPIPaginated(endpoint, timeout:) are not silently
        // overridden by apiPaginated's 60-second default.
        configureGHAPIPaginated { endpoint, timeout in
            await sharedGitHubTransport.apiPaginated(endpoint, timeout: timeout)
        }
        setupStatusItem()
        setupPanel()
        setupSignOutSubscription()
        // Migrate legacy flat UserDefaults keys → single JSON blob per scope.
        // Must run after ScopeStore is set up (setupPanel → setupSubscriptions
        // initialises ScopeStore.shared), before any ScopePreferencesStore reads.
        // Plain Task{} — inherits @MainActor from AppDelegate, so knownScopes is
        // read on main and the await crosses to the actor safely. (#1538)
        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        Task {
            await ScopePreferencesStore.shared.migrateIfNeeded(knownScopes: knownScopes)
            // Re-hydrate cached display names after migration so ScopesView shows
            // aliases immediately on first launch. (#1538)
            await ScopeStore.shared.refreshDisplayNames()
        }
        log("AppDelegate › applicationDidFinishLaunching — migration task enqueued for \(knownScopes.count) scopes")
    }
}
