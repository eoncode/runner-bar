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
/// ### Why `skipCodeSignValidation` is NOT set
/// `AppUpdater` v2 removed the `skipCodeSignValidation` property. Code-sign
/// validation now happens inside `checkThrowing()`: if either identity is `nil`
/// (ad-hoc signing produces no `Authority=` line) the check throws
/// `.codeSigningIdentity` and the update is skipped. For ad-hoc builds this
/// means auto-update silently no-ops at validation, which is acceptable for
/// local/CI distribution. Production builds signed with a Developer ID cert
/// will update normally. (ref issue #345)
///
/// ### Background checks
/// `NSBackgroundActivityScheduler` inside `AppUpdater` fires every 24 h
/// automatically. Accessing `.shared` is sufficient to start it.
final class AppUpdaterService: ObservableObject {
    /// Shared singleton — initialised once at app launch.
    static let shared = AppUpdaterService()

    /// The underlying updater. `SettingsView` observes `updater.downloadedAppBundle`
    /// directly via `@ObservedObject` to drive the install button.
    let updater: AppUpdater = {
        // ⚠️ owner must match the GitHub org/user that publishes Releases.
        // Releases live under eoncode/runner-bar, NOT eonist/runner-bar.
        let instance = AppUpdater(owner: "eoncode", repo: "runner-bar")
        return instance
    }()

    /// `true` while a manual `check()` call is in-flight.
    /// Drives the "Checking…" spinner in `SettingsView.updateRow`.
    @Published var isChecking = false

    private init() {}

    /// Triggers a foreground update check and updates `isChecking`.
    func checkForUpdates() {
        isChecking = true
        updater.check(
            { [weak self] in
                DispatchQueue.main.async { self?.isChecking = false }
            },
            { [weak self] _ in
                DispatchQueue.main.async { self?.isChecking = false }
            }
        )
    }
}
