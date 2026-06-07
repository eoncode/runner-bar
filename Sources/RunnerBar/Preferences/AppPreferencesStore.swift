// AppPreferencesStore.swift
// RunnerBar
import Combine
import Foundation

// MARK: - AppPreferencesStore

/// Persists general app settings to UserDefaults.
@MainActor
final class AppPreferencesStore: ObservableObject {
    /// Shared singleton — use this instead of calling init directly.
    static let shared = AppPreferencesStore()

    /// UserDefaults key constants used by `AppPreferencesStore`.
    private enum Key {
        /// Key for the polling interval setting.
        static let pollingInterval   = "settings.pollingInterval"
        /// Key for the show-dimmed-runners toggle.
        static let showDimmedRunners = "settings.showDimmedRunners"
        /// Key for the show-popover-arrow toggle.
        static let showPopoverArrow  = "settings.showPopoverArrow"
    }

    /// Valid range for the polling interval in seconds. Minimum 10 s, maximum 300 s.
    static let pollingRange: ClosedRange<Int> = 10 ... 300

    /// How often (in seconds) RunnerBar polls GitHub. Clamped to 10–300 s.
    ///
    /// Setting this property out-of-range triggers a second `didSet` call with
    /// the clamped value — this re-entrancy is intentional and safe because
    /// `AppPreferencesStore` is `@MainActor`-isolated (all mutations are serialised
    /// on the main queue, so the recursive assignment cannot interleave).
    @Published var pollingInterval: Int {
        didSet {
            let clamped = pollingInterval.clamped(to: Self.pollingRange)
            if clamped != pollingInterval {
                pollingInterval = clamped
                return
            }
            UserDefaults.standard.set(pollingInterval, forKey: Key.pollingInterval)
        }
    }

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would break the stored key for
    /// users upgrading from older versions.
    @Published var showDimmedRunners: Bool {
        didSet { UserDefaults.standard.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    /// Whether the NSPopover anchor arrow is shown.
    ///
    /// When `false`, the arrow is suppressed on the next popover open via the
    /// private-but-widely-used KVC key `shouldHideAnchor` on `NSPopover`.
    /// Default is `true` so existing users see no behaviour change on upgrade.
    ///
    /// Takes effect on the next `openPanel()` call — the arrow state is baked in
    /// at `popover.show()` time and cannot be changed mid-session.
    @Published var showPopoverArrow: Bool {
        didSet { UserDefaults.standard.set(showPopoverArrow, forKey: Key.showPopoverArrow) }
    }

    /// Private initialiser — use `shared`.
    ///
    /// Registers factory defaults first so both `integer(forKey:)` and `bool(forKey:)`
    /// return the intended values on first launch without requiring `object(forKey:) == nil`
    /// guards. This matches the pattern used by `NotificationPreferences`.
    private init() {
        UserDefaults.standard.register(defaults: [
            Key.pollingInterval:   15,  // First-launch default: 15 s (see #511)
            Key.showDimmedRunners: true,
            Key.showPopoverArrow:  true,
        ])
        let stored = UserDefaults.standard.integer(forKey: Key.pollingInterval)
        pollingInterval   = stored.clamped(to: Self.pollingRange)
        showDimmedRunners = UserDefaults.standard.bool(forKey: Key.showDimmedRunners)
        showPopoverArrow  = UserDefaults.standard.bool(forKey: Key.showPopoverArrow)
    }
}

// MARK: - Comparable+clamped

/// Constrains a `Comparable` value to a closed range, returning `lowerBound`
/// when the value is below the range and `upperBound` when it is above.
///
/// Declared `private` to avoid polluting the global `Comparable` namespace —
/// this helper is an implementation detail of `AppPreferencesStore`.
private extension Comparable {
    /// Returns the value clamped to `range`, i.e. `max(lowerBound, min(self, upperBound))`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
