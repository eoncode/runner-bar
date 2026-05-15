import Foundation
import Combine

// MARK: - SettingsStore
/// Persists user-configurable app settings to `UserDefaults`.
/// All properties publish changes so views and services can react immediately.
final class SettingsStore: ObservableObject {
    /// GitHub Personal Access Token used to authenticate API calls.
    @Published var githubToken: String {
        didSet { UserDefaults.standard.set(githubToken, forKey: Keys.githubToken) }
    }
    /// The GitHub org or user whose runners and workflows are monitored.
    @Published var githubOrg: String {
        didSet { UserDefaults.standard.set(githubOrg, forKey: Keys.githubOrg) }
    }
    /// How often (in seconds) to poll the GitHub API for updates.
    @Published var pollingInterval: Double {
        didSet { UserDefaults.standard.set(pollingInterval, forKey: Keys.pollingInterval) }
    }
    /// Whether offline (idle) runners should be shown in the runner list.
    @Published var showOfflineRunners: Bool {
        didSet { UserDefaults.standard.set(showOfflineRunners, forKey: Keys.showOfflineRunners) }
    }
    /// Whether the app should launch automatically at login.
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    init() {
        let ud = UserDefaults.standard
        githubToken       = ud.string(forKey: Keys.githubToken) ?? ""
        githubOrg         = ud.string(forKey: Keys.githubOrg) ?? ""
        pollingInterval   = ud.object(forKey: Keys.pollingInterval) as? Double ?? 30
        // Migration: honour legacy key "showIdleRunners" (inverted) if the new key is absent.
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
        static let githubToken       = "githubToken"
        static let githubOrg         = "githubOrg"
        static let pollingInterval   = "pollingInterval"
        static let showOfflineRunners = "showOfflineRunners"
        static let launchAtLogin     = "launchAtLogin"
    }
}
