import Combine
import Foundation

// MARK: - SettingsStore

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    /// Shared singleton instance.
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval = "settings.pollingInterval"
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

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        let raw = stored > 0 ? stored : 30
        pollingInterval = raw.clamped(to: Self.pollingRange)
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
