import Combine
import Foundation

// MARK: - SettingsStore

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval   = "settings.pollingInterval"
        // Legacy key — kept so existing UserDefaults values are not lost on upgrade.
        static let showDimmedRunners = "settings.showDimmedRunners"
        // New canonical key introduced in Issue #419 Phase 5 / SettingsView rename.
        static let showOfflineRunners = "settings.showOfflineRunners"
    }

    /// Valid range for the polling interval (seconds).
    static let pollingRange: ClosedRange<Int> = 10 ... 300

    /// How often (in seconds) RunnerBar polls GitHub. Clamped to 10–300 s.
    @Published var pollingInterval: Int {
        didSet {
            let clamped = pollingInterval.clamped(to: Self.pollingRange)
            if clamped != pollingInterval {
                pollingInterval = clamped
                return
            }
            UserDefaults.standard.set(pollingInterval, forKey: Key.pollingInterval)
        }
    }

    /// Whether offline / dimmed runners are shown in the list.
    /// `showOfflineRunners` is the canonical name used by SettingsView (Issue #419 Phase 5).
    /// `showDimmedRunners` is retained as a computed alias so existing call-sites compile
    /// without a breaking change until they are migrated.
    @Published var showOfflineRunners: Bool {
        didSet {
            UserDefaults.standard.set(showOfflineRunners, forKey: Key.showOfflineRunners)
            // Keep legacy key in sync so a downgrade still reads the right value.
            UserDefaults.standard.set(showOfflineRunners, forKey: Key.showDimmedRunners)
        }
    }

    /// Deprecated alias — mirrors `showOfflineRunners`. Kept for source compatibility.
    var showDimmedRunners: Bool {
        get { showOfflineRunners }
        set { showOfflineRunners = newValue }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        let raw = stored > 0 ? stored : 30
        pollingInterval = raw.clamped(to: Self.pollingRange)

        // Migrate: prefer new key; fall back to legacy key if new key has never been written.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.showOfflineRunners) != nil {
            showOfflineRunners = defaults.bool(forKey: Key.showOfflineRunners)
        } else {
            showOfflineRunners = defaults.bool(forKey: Key.showDimmedRunners)
        }
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
