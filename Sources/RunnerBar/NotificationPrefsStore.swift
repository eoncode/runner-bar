import Combine
import Foundation

// MARK: - NotificationPrefsStore

/// Persists notification preferences to UserDefaults.
/// Provides `notifyOnSuccess` and `notifyOnFailure` for the Notifications section of SettingsView.
final class NotificationPrefsStore: ObservableObject { // swiftlint:disable:this type_body_length
    static let shared = NotificationPrefsStore()

    private enum Key {
        static let notifyOnSuccess = "notifications.notifyOnSuccess"
        static let notifyOnFailure = "notifications.notifyOnFailure"
    }

    /// Whether to notify when a job succeeds (default true).
    @Published var notifyOnSuccess: Bool {
        didSet { UserDefaults.standard.set(notifyOnSuccess, forKey: Key.notifyOnSuccess) }
    }

    /// Whether to notify when a job fails (default true).
    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Key.notifyOnFailure) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Key.notifyOnSuccess) == nil {
            notifyOnSuccess = true
        } else {
            notifyOnSuccess = UserDefaults.standard.bool(forKey: Key.notifyOnSuccess)
        }
        if UserDefaults.standard.object(forKey: Key.notifyOnFailure) == nil {
            notifyOnFailure = true
        } else {
            notifyOnFailure = UserDefaults.standard.bool(forKey: Key.notifyOnFailure)
        }
    }
}
