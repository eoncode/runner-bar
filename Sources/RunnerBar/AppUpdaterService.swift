import AppUpdater
import Foundation

// MARK: - AppUpdaterService

/// Singleton wrapper around `AppUpdater` (v2) so `SettingsView` can observe
/// update state via `@ObservedObject` without importing `AppDelegate`.
///
/// ### v2 API surface used
/// - `updater.downloadedAppBundle: Bundle?` — non-nil when a newer version
///   has been downloaded and is ready to install. Observe via `@ObservedObject`.
/// - `updater.check()` — triggers an immediate async release check.
/// - `updater.install(_:)` — replaces the running `.app` and relaunches.
///
/// ### Signing + auto-update behaviour
/// This project uses ad-hoc signing (`codesign --force --deep --sign -`).
/// AppUpdater v2 validates code-signing identity by comparing `Authority=`
/// lines from `codesign -dvvv`; ad-hoc builds produce no such line, so both
/// identities resolve to `nil` and `checkThrowing()` throws `.codeSigningIdentity`,
/// causing auto-update to silently no-op for distributed builds.
/// To enable self-update for end users, release artifacts must be signed with
/// a Developer ID certificate. (ref issue #345)
///
/// ### Background checks
/// `NSBackgroundActivityScheduler` inside `AppUpdater` fires every 24 h
/// automatically. Accessing `.shared` is sufficient to start it.
final class AppUpdaterService: ObservableObject {
    /// Shared singleton — initialised once at app launch.
    static let shared = AppUpdaterService()

    /// The underlying updater. `SettingsView` observes this instance
    /// **directly** via `@ObservedObject` so `downloadedAppBundle` changes
    /// trigger view re-renders without needing a forwarding publisher.
    ///
    /// ⚠️ `owner` must match the GitHub org/user that publishes Releases.
    /// Releases live under `eoncode/runner-bar`, NOT `eonist/runner-bar`.
    /// NB: gh-pages is hosted under `eonist/runner-bar` (install.sh bootstrap),
    /// but GitHub Releases (AppUpdater source) live under `eoncode/runner-bar`.
    /// See DEPLOYMENT.md for the rationale.
    let updater = AppUpdater(owner: "eoncode", repo: "runner-bar")

    /// `true` while a manual `checkForUpdates()` call is in-flight.
    /// Drives the "Checking…" spinner in `SettingsView.updateRow`.
    @Published var isChecking = false

    /// Non-nil if the last manual check failed. Drives the "Check failed" row
    /// in `SettingsView.updateRow`. Cleared on the next `checkForUpdates()` call.
    @Published var lastCheckError: Error?

    // Intentionally empty: singleton construction is fully handled
    // by the `updater` property initialiser above.
    private init() {}

    /// Triggers a foreground update check and updates `isChecking`.
    func checkForUpdates() {
        isChecking = true
        lastCheckError = nil
        updater.check(
            { [weak self] in
                DispatchQueue.main.async { self?.isChecking = false }
            },
            { [weak self] error in
                DispatchQueue.main.async {
                    self?.isChecking = false
                    self?.lastCheckError = error
                }
                Logger.log("AppUpdater check failed: \(error)")
            }
        )
    }
}
