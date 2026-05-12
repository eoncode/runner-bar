import Combine
import Foundation

// MARK: - NotificationPrefsStore

/// Persists notification preferences to UserDefaults.
final class NotificationPrefsStore: ObservableObject {
    static let shared = NotificationPrefsStore()

    private enum Key {
        static let notifyOnSuccess = "notifications.notifyOnSuccess"
        static let notifyOnFailure = "notifications.notifyOnFailure"
    }

    /// Whether the user wants a notification when a job succeeds.
    @Published var notifyOnSuccess: Bool {
        didSet { UserDefaults.standard.set(notifyOnSuccess, forKey: Key.notifyOnSuccess) }
    }

    /// Whether the user wants a notification when a job fails.
    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Key.notifyOnFailure) }
    }

    private init() {
        let defaults = UserDefaults.standard
        notifyOnSuccess = defaults.object(forKey: Key.notifyOnSuccess) == nil
            ? true
            : defaults.bool(forKey: Key.notifyOnSuccess)
        notifyOnFailure = defaults.object(forKey: Key.notifyOnFailure) == nil
            ? true
            : defaults.bool(forKey: Key.notifyOnFailure)
    }
}
