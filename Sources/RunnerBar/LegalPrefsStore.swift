import Combine
import Foundation

// MARK: - LegalPrefsStore

/// Persists legal/privacy preferences to UserDefaults.
/// Phase 6 (ref #221): analytics opt-in toggle.
/// Pattern mirrors NotificationPrefsStore — @Published + didSet.
final class LegalPrefsStore: ObservableObject {
    static let shared = LegalPrefsStore()

    private enum Key {
        /// Analytics opt-in flag. Default is false (opt-in, not opt-out).
        static let analyticsEnabled = "legal.analyticsEnabled"
    }

    /// Whether the user has opted in to sharing analytics (default false).
    @Published var analyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: Key.analyticsEnabled) }
    }

    private init() {
        // Treat missing key as false (opt-in — user must explicitly enable).
        guard UserDefaults.standard.object(forKey: Key.analyticsEnabled) != nil else {
            analyticsEnabled = false
            return
        }
        analyticsEnabled = UserDefaults.standard.bool(forKey: Key.analyticsEnabled)
    }
}
