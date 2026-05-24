// LegalPreferences.swift
// RunnerBar
import Combine
import Foundation

// MARK: - LegalPreferences
// periphery:ignore
/// Persists legal/analytics preferences to UserDefaults.
/// `analyticsEnabled` defaults to `false` (opt-in, not opt-out) per issue #221/#245.
@MainActor
final class LegalPreferences: ObservableObject {
    /// The shared constant.
    static let shared = LegalPreferences()

    /// UserDefaults key constants.
    private enum Key {
        /// Key for the analytics opt-in flag.
        static let analyticsEnabled = "legal.analyticsEnabled"
    }

    /// Whether the user has opted in to analytics (default false — opt-in).
    @Published var analyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: Key.analyticsEnabled) }
    }

    /// Private initialiser — use `shared`.
    private init() {
        // Explicit nil-check: treat absent key as false (opt-in, never assume consent).
        if UserDefaults.standard.object(forKey: Key.analyticsEnabled) == nil {
            analyticsEnabled = false
        } else {
            analyticsEnabled = UserDefaults.standard.bool(forKey: Key.analyticsEnabled)
        }
    }
}
