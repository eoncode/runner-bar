import Combine
import Foundation

// MARK: - NotificationPrefsStore

/// Persists notification preferences to UserDefaults.
///
/// Default values are registered via `UserDefaults.register(defaults:)` in
/// `init()`, the idiomatic macOS pattern. This removes the per-read nil-coalescing
/// guards and lets `bool(forKey:)` return the default value automatically.
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
        // Register factory defaults once so bool(forKey:) returns them
        // even before the user has ever changed a preference.
        UserDefaults.standard.register(defaults: [
            Key.notifyOnSuccess: true,
            Key.notifyOnFailure: true,
        ])
        notifyOnSuccess = UserDefaults.standard.bool(forKey: Key.notifyOnSuccess)
        notifyOnFailure = UserDefaults.standard.bool(forKey: Key.notifyOnFailure)
    }
}
