import Combine
import Foundation

// MARK: - NotificationPrefsStore

/// Persists notification preferences to UserDefaults.
/// Provides `notifyOnSuccess` and `notifyOnFailure` for the Notifications section of SettingsView.
final class NotificationPrefsStore: ObservableObject {
    static let shared = NotificationPrefsStore()

    private enum Key {
        static let notifyOnSuccess = "notifications.notifyOnSuccess"
        static let notifyOnFailure = "notifications.notifyOnFailure"
        /// Sentinel key: set to true once defaults have been written on first launch.
        /// Prevents re-applying defaults when the user explicitly toggles to true later.
        static let defaultsApplied = "notifications.defaultsApplied"
    }

    /// Whether to notify when a job succeeds.
    /// #20: Default is FALSE on first launch — users opt in rather than being spammed.
    @Published var notifyOnSuccess: Bool {
        didSet { UserDefaults.standard.set(notifyOnSuccess, forKey: Key.notifyOnSuccess) }
    }

    /// Whether to notify when a job fails.
    /// #20: Default is FALSE on first launch — users opt in rather than being spammed.
    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Key.notifyOnFailure) }
    }

    private init() {
        // #20: On first launch (sentinel key absent) default BOTH to false.
        // On subsequent launches read whatever the user last set.
        // ⚠️ Do NOT change the sentinel check to object(forKey:) == nil on the
        //    individual keys — if the user turned a toggle ON, it writes true;
        //    a future cold-start would then see object != nil and correctly
        //    keep the user's choice. The sentinel is the right guard here.
        if UserDefaults.standard.object(forKey: Key.defaultsApplied) == nil {
            // First launch: write the off-by-default values and mark applied.
            notifyOnSuccess = false
            notifyOnFailure = false
            UserDefaults.standard.set(false, forKey: Key.notifyOnSuccess)
            UserDefaults.standard.set(false, forKey: Key.notifyOnFailure)
            UserDefaults.standard.set(true,  forKey: Key.defaultsApplied)
        } else {
            // Subsequent launches: honour whatever the user last saved.
            notifyOnSuccess = UserDefaults.standard.bool(forKey: Key.notifyOnSuccess)
            notifyOnFailure = UserDefaults.standard.bool(forKey: Key.notifyOnFailure)
        }
    }
}
