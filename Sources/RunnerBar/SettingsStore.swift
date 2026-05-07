import Combine
import Foundation

// MARK: - SettingsStore

/// Persists user preferences to UserDefaults.
/// Provides `showDimmedRunners` and `pollingInterval` for the General section of SettingsView.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval = "settings.pollingInterval"
        static let showDimmedRunners = "settings.showDimmedRunners"
    }

    /// Polling interval in seconds (default 30, range 10–300).
    @Published var pollingInterval: Int {
        didSet { UserDefaults.standard.set(pollingInterval, forKey: Key.pollingInterval) }
    }

    /// Whether dimmed (offline) runners are shown in the list (default true).
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        pollingInterval = stored > 0 ? stored : 30
        if UserDefaults.standard.object(forKey: Key.showDimmedRunners) == nil {
            showDimmedRunners = true
        } else {
            showDimmedRunners = UserDefaults.standard.bool(forKey: Key.showDimmedRunners)
        }
    }
}
