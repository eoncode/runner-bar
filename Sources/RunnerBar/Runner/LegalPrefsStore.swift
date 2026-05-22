import Combine
import Foundation

// MARK: - LegalPrefsStore

/// Persists legal/analytics preferences to UserDefaults.
/// `analyticsEnabled` defaults to `false` (opt-in, not opt-out) per issue #221/#245.
final class LegalPrefsStore: ObservableObject {
    static let shared = LegalPrefsStore()

    private enum Key {
        static let analyticsEnabled = "legal.analyticsEnabled"
    }

    /// Whether the user has opted in to analytics (default false — opt-in).
    @Published var analyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: Key.analyticsEnabled) }
    }

    private init() {
        // Explicit nil-check: treat absent key as false (opt-in, never assume consent).
        if UserDefaults.standard.object(forKey: Key.analyticsEnabled) == nil {
            analyticsEnabled = false
        } else {
            analyticsEnabled = UserDefaults.standard.bool(forKey: Key.analyticsEnabled)
        }
    }
}
