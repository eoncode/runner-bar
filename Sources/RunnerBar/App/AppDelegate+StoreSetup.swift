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

    /// Entry point after launch. Configures the GitHub API clients, migrates
    /// per-scope preferences from the legacy flat-key format to the single-blob
    /// actor, then builds the status-bar item and NSPopover panel. (#1538)
    ///
    /// ## Startup ordering
    /// Migration MUST complete before `setupPanel()` so that `RunnerStore`
    /// observers spawned inside `setupPanel → setupSubscriptions` never read
    /// `ScopePreferencesStore` before the v2 blobs exist. The sequence is:
    ///
    ///  1. Configure transports (synchronous, no actor reads).
    ///  2. Await `migrateIfNeeded` — writes v2 blobs, removes legacy flat keys.
    ///  3. Await `refreshDisplayNames` — hydrates `ScopeEntry.displayName` cache.
    ///  4. `setupStatusItem` / `setupPanel` / `setupSignOutSubscription` — UI and
    ///     observers start only after migration is complete.
    ///
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
        // Read knownScopes synchronously before the Task — ScopeStore.shared is
        // @MainActor and we are already on @MainActor here. (#1538)
        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        log("AppDelegate › applicationDidFinishLaunching — migration task starting for \(knownScopes.count) scopes")
        // Migrate, hydrate display names, THEN start UI and observers.
        // Plain Task{} inherits @MainActor from AppDelegate; all three setup
        // calls below run on the main actor after the two awaits resolve. (#1538)
        Task {
            // Step 2: migrate legacy flat keys → v2 blobs.
            await ScopePreferencesStore.shared.migrateIfNeeded(knownScopes: knownScopes)
            // Step 3: hydrate ScopeEntry.displayName from freshly-migrated blobs.
            await ScopeStore.shared.refreshDisplayNames()
            // Step 4: start UI and observers — guaranteed to see migrated prefs.
            setupStatusItem()
            setupPanel()
            setupSignOutSubscription()
            log("AppDelegate › applicationDidFinishLaunching — DONE")
        }
    }
}
