import Combine
import Foundation

// MARK: - SettingsStore
// swiftlint:disable file_length

/// Persists general app settings to UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let pollingInterval = "settings.pollingInterval"
        static let showDimmedRunners = "settings.showDimmedRunners"
    }

    /// How often (in seconds) RunnerBar polls GitHub. Default 30 s.
    @Published var pollingInterval: Int {
        didSet { UserDefaults.standard.set(pollingInterval, forKey: Key.pollingInterval) }
    }

    /// Whether offline/dimmed runners are shown in the list.
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        pollingInterval = stored > 0 ? stored : 30
        showDimmedRunners = UserDefaults.standard.bool(forKey: Key.showDimmedRunners)
    }
}
// swiftlint:enable file_length
