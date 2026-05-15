// swiftlint:disable missing_docs
// swiftlint:disable all
import Foundation

/// Legal preferences storage.
final class LegalPrefsStore: ObservableObject {
    /// Whether privacy policy has been accepted.
    @Published var hasAcceptedPrivacy: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedPrivacy, forKey: Key.privacy) }
    }
    /// Whether terms have been accepted.
    @Published var hasAcceptedTerms: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedTerms, forKey: Key.terms) }
    }
    /// Initialises from UserDefaults.
    init() {
        hasAcceptedPrivacy = UserDefaults.standard.bool(forKey: Key.privacy)
        hasAcceptedTerms = UserDefaults.standard.bool(forKey: Key.terms)
    }
    private enum Key {
        static let privacy = "legalPrefs.hasAcceptedPrivacy"
        static let terms = "legalPrefs.hasAcceptedTerms"
    }
}
