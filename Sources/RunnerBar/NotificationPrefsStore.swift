import Combine
import Foundation

// MARK: - NotificationPrefsStore

/// Persists notification preferences to UserDefaults.
/// Phase 4 (ref #221): success and failure notification toggles.
final class NotificationPrefsStore: ObservableObject {
    static let shared = NotificationPrefsStore()

    private enum Key {
        static let notifyOnSuccess = "notifications.notifyOnSuccess"
        static let notifyOnFailure = "notifications.notifyOnFailure"
    }

    /// Send a notification when a job completes successfully (default true).
    @Published var notifyOnSuccess: Bool {
        didSet { UserDefaults.standard.set(notifyOnSuccess, forKey: Key.notifyOnSuccess) }
    }

    /// Send a notification when a job fails (default true).
    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Key.notifyOnFailure) }
    }

    private init() {
        func boolPref(_ key: String, default defaultValue: Bool) -> Bool {
            guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
            return UserDefaults.standard.bool(forKey: key)
        }
        notifyOnSuccess = boolPref(Key.notifyOnSuccess, default: true)
        notifyOnFailure = boolPref(Key.notifyOnFailure, default: true)
    }
}
