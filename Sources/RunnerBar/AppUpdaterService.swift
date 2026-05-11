import AppUpdater
import Foundation

// MARK: - AppUpdaterService

/// Singleton wrapper around `AppUpdater` (v0.x) so `SettingsView` can observe
/// update state via `@ObservedObject` without importing `AppDelegate`.
///
/// ### v0.x API surface used
/// - `updater.state: AppUpdater.State` — published enum driving `updateRow`.
///   Cases: `.none`, `.downloading(Release, Double)`, `.downloaded(Bundle)`.
/// - `updater.check()` — triggers an immediate async release check.
/// - `updater.install(_:)` — replaces the running `.app` and relaunches.
/// - `updater.skipCodeSignValidation` — set `true` for ad-hoc signed builds.
///
/// ### Signing + auto-update behaviour
/// This project uses ad-hoc signing (`codesign --force --deep --sign -`).
/// `skipCodeSignValidation = true` is required to allow installs without a
/// Developer ID certificate. The comment is intentional — do not remove it.
/// We own both the running app and the release artifact (ref issue #345).
///
/// ### Background checks
/// `NSBackgroundActivityScheduler` inside `AppUpdater` fires every 24 h
/// automatically. `AppDelegate` also fires an eager `checkForUpdates()` on
/// launch so users see current state the first time they open Settings → About.
final class AppUpdaterService: ObservableObject {
    /// Shared singleton — initialised once at app launch.
    static let shared = AppUpdaterService()

    /// The underlying updater. `SettingsView` observes this instance
    /// **directly** via `@ObservedObject` so `state` changes trigger re-renders.
    ///
    /// ⚠️ `owner` must match the GitHub org/user that publishes Releases.
    /// Releases live under `eoncode/runner-bar`, NOT `eonist/runner-bar`.
    /// NB: gh-pages is hosted under `eonist/runner-bar` (install.sh bootstrap),
    /// but GitHub Releases (AppUpdater source) live under `eoncode/runner-bar`.
    /// See DEPLOYMENT.md for the rationale.
    let updater: AppUpdater = {
        let instance = AppUpdater(owner: "eoncode", repo: "runner-bar")
        // Required for ad-hoc signed builds — see class-level comment.
        instance.skipCodeSignValidation = true
        return instance
    }()

    /// `true` while a manual `checkForUpdates()` call is in-flight.
    /// Drives the "Checking…" spinner in `SettingsView.updateRow`.
    @Published var isChecking = false

    /// Non-nil if the last manual check or install failed. Drives the "Check failed" row
    /// in `SettingsView.updateRow`. Cleared on the next `checkForUpdates()` call.
    @Published var lastCheckError: Error?

    private init() {
        // Intentionally empty: singleton construction is fully handled
        // by the `updater` property initialiser above.
    }

    /// Triggers a foreground update check and updates `isChecking`.
    /// Guards against concurrent in-flight calls — safe to call from a button action.
    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        lastCheckError = nil
        updater.check(
            { [self] in
                DispatchQueue.main.async { self.isChecking = false }
            },
            { [self] error in
                DispatchQueue.main.async {
                    self.isChecking = false
                    self.lastCheckError = error
                }
                Logger.log("AppUpdater check failed: \(error)")
            }
        )
    }
}
