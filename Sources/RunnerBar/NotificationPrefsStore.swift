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
        NotificationPrefsStore.register(defaults: .standard)
        notifyOnSuccess = UserDefaults.standard.bool(forKey: Key.notifyOnSuccess)
        notifyOnFailure = UserDefaults.standard.bool(forKey: Key.notifyOnFailure)
    }

    /// Registers factory defaults so that `bool(forKey:)` returns the intended
    /// value on first launch without requiring a `object(forKey:) == nil` guard.
    ///
    /// Call once at app startup (e.g. from `applicationDidFinishLaunching`) and
    /// again in unit tests before exercising notification logic.
    static func register(defaults: UserDefaults) {
        defaults.register(defaults: [
            Key.notifyOnSuccess: true,
            Key.notifyOnFailure: true,
        ])
    }
}
