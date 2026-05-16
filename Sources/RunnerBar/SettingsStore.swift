// swiftlint:disable missing_docs
import Combine
import Foundation

// MARK: - SettingsStore
final class SettingsStore: ObservableObject {
    /// Shared singleton — consumed by RunnerStore (Combine subscription + polling interval)
    /// and injected into the SwiftUI environment by AppDelegate.
    static let shared = SettingsStore()

    @Published var githubToken: String {
        didSet { UserDefaults.standard.set(githubToken, forKey: Keys.githubToken) }
    }
    @Published var githubOrg: String {
        didSet { UserDefaults.standard.set(githubOrg, forKey: Keys.githubOrg) }
    }
    @Published var pollingInterval: Double {
        didSet { UserDefaults.standard.set(pollingInterval, forKey: Keys.pollingInterval) }
    }
    @Published var showOfflineRunners: Bool {
        didSet { UserDefaults.standard.set(showOfflineRunners, forKey: Keys.showOfflineRunners) }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    init() {
        let ud = UserDefaults.standard
        githubToken       = ud.string(forKey: Keys.githubToken) ?? ""
        githubOrg         = ud.string(forKey: Keys.githubOrg) ?? ""
        pollingInterval   = ud.object(forKey: Keys.pollingInterval) as? Double ?? 30
        if ud.object(forKey: Keys.showOfflineRunners) != nil {
            showOfflineRunners = ud.bool(forKey: Keys.showOfflineRunners)
        } else if ud.object(forKey: "showIdleRunners") != nil {
            showOfflineRunners = !ud.bool(forKey: "showIdleRunners")
        } else {
            showOfflineRunners = false
        }
        launchAtLogin = ud.bool(forKey: Keys.launchAtLogin)
    }

    private enum Keys {
        static let githubToken        = "githubToken"
        static let githubOrg          = "githubOrg"
        static let pollingInterval    = "pollingInterval"
        static let showOfflineRunners = "showOfflineRunners"
        static let launchAtLogin      = "launchAtLogin"
    }
}
// swiftlint:enable missing_docs
