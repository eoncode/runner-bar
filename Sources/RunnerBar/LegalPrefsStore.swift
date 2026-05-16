// swiftlint:disable all
import Foundation
import SwiftUI

/// Stores legal/privacy preferences and exposes a shared singleton for
/// AppDelegate environment injection.
final class LegalPrefsStore: ObservableObject {
    static let shared = LegalPrefsStore()

    @Published var hasAcceptedTerms: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedTerms, forKey: "legalPrefs.hasAcceptedTerms") }
    }

    init() {
        hasAcceptedTerms = UserDefaults.standard.bool(forKey: "legalPrefs.hasAcceptedTerms")
    }
}
