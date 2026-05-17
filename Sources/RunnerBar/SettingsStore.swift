import Combine
import Foundation

// MARK: - SettingsStore

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    /// Shared singleton instance.
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval = "settings.pollingInterval"
        static let showDimmedRunners = "settings.showDimmedRunners"
    }

    /// Valid range for the polling interval (seconds).
    static let pollingRange: ClosedRange<Int> = 10 ... 300

    /// How often (in seconds) RunnerBar polls GitHub. Clamped to 10–300 s.
    ///
    /// didSet contract:
    ///   1. Clamp the new value to pollingRange.
    ///   2. If clamping was needed, write back the clamped value and return —
    ///      the second didSet will hit the else branch and persist.
    ///   3. If already in range, persist to UserDefaults immediately.
    ///
    /// ❌ NEVER write UserDefaults inside the `else` branch — doing so
    ///    causes an infinite didSet → Combine → scheduleTimer → fetch loop
    ///    that drains the entire GitHub API quota in seconds.
    @Published var pollingInterval: Int {
        didSet {
            let clamped = pollingInterval.clamped(to: Self.pollingRange)
            if clamped != pollingInterval {
                // Out of range — clamp and return. The reassignment triggers
                // didSet once more; that call hits the else branch below.
                pollingInterval = clamped
                return
            }
            // Value is valid — persist.
            UserDefaults.standard.set(pollingInterval, forKey: Key.pollingInterval)
        }
    }

    /// Whether offline/dimmed runners are shown in the list.
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        let raw = stored > 0 ? stored : 30
        pollingInterval = raw.clamped(to: Self.pollingRange)
        showDimmedRunners = UserDefaults.standard.bool(forKey: Key.showDimmedRunners)
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
