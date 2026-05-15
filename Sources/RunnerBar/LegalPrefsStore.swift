import Foundation

// MARK: - LegalPrefsStore
/// Persists the user's acceptance of the Privacy Policy and Terms of Service.
/// Values are stored in `UserDefaults.standard` under namespaced keys.
final class LegalPrefsStore: ObservableObject {
    /// Whether the user has accepted the Privacy Policy.
    @Published var hasAcceptedPrivacy: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedPrivacy, forKey: Key.privacy) }
    }
    /// Whether the user has accepted the Terms of Service.
    @Published var hasAcceptedTerms: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedTerms, forKey: Key.terms) }
    }

    init() {
        hasAcceptedPrivacy = UserDefaults.standard.bool(forKey: Key.privacy)
        hasAcceptedTerms   = UserDefaults.standard.bool(forKey: Key.terms)
    }

    private enum Key {
        static let privacy = "legalPrefs.hasAcceptedPrivacy"
        static let terms   = "legalPrefs.hasAcceptedTerms"
    }
}
