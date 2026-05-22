import Combine
import Foundation

// MARK: - SettingsStore

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    /// Shared singleton instance.
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval    = "settings.pollingInterval"
        static let showDimmedRunners  = "settings.showDimmedRunners"
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

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    /// Retained for backwards compat but no longer surfaced in the UI (#510).
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        // #511: Default changed from 30 s to 15 s for more responsive monitoring.
        let raw = stored > 0 ? stored : 15
        pollingInterval = raw.clamped(to: Self.pollingRange)

        if UserDefaults.standard.object(forKey: Key.showDimmedRunners) == nil {
            showDimmedRunners = true
        } else {
            showDimmedRunners = UserDefaults.standard.bool(forKey: Key.showDimmedRunners)
        }
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
