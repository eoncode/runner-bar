import Combine
import Foundation

// MARK: - SettingsStore

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    /// Shared singleton instance.
    static let shared = SettingsStore()

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
            UserDefaults.standard.set(pollingInterval, forKey: "settings.pollingInterval")
        }
    }

    /// Whether offline/dimmed runners are shown in the list.
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: "settings.showDimmedRunners") }
    }

    /// Initialises from UserDefaults, clamping the stored polling interval.
    init() {
        let stored = UserDefaults.standard.integer(forKey: "settings.pollingInterval")
        let raw = stored > 0 ? stored : 30
        pollingInterval = raw.clamped(to: Self.pollingRange)
        showDimmedRunners = UserDefaults.standard.bool(forKey: "settings.showDimmedRunners")
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    /// Returns this value clamped to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
