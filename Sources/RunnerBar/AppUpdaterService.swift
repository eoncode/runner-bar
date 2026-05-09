import AppUpdater
import Foundation

// MARK: - AppUpdaterService

/// Singleton wrapper around `AppUpdater` so `SettingsView` can observe
/// update state via `@ObservedObject` without importing `AppDelegate`.
///
/// - `skipCodeSignValidation` is `true` because runner-bar uses ad-hoc
///   signing (`codesign --sign -`), which emits no `Authority=` line in
///   `codesign -dvvv` output. AppUpdater interprets both `csi` values as
///   `nil` and gates on this flag — setting it `true` lets the update
///   proceed. We own both the running app and the release artifact, so
///   this is safe. (ref issue #345)
///
/// - Background update checks fire automatically every 24 h via
///   `NSBackgroundActivityScheduler` inside `AppUpdater`.
final class AppUpdaterService: ObservableObject {
    /// Shared singleton — initialised once at app launch.
    static let shared = AppUpdaterService()

    /// The underlying updater. `SettingsView` observes `updater.state`
    /// directly via `@ObservedObject`.
    let updater: AppUpdater = {
        let instance = AppUpdater(owner: "eonist", repo: "runner-bar")
        // ⚠️ REQUIRED for ad-hoc signed builds — see header comment.
        instance.skipCodeSignValidation = true
        return instance
    }()

    private init() {}
}
