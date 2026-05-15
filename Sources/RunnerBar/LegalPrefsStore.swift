// swiftlint:disable all
// swiftlint:disable all
import Foundation

final class LegalPrefsStore: ObservableObject {
    @Published var hasAcceptedPrivacy: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedPrivacy, forKey: Key.privacy) }
    }
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
