// AppPreferencesStore.swift
// RunnerBar
import Foundation
import Observation

// MARK: - AppPreferencesStore

/// Persists general app settings to UserDefaults.
///
/// ## Dependency injection (P7)
/// `init(store:)` accepts a `UserDefaults` suite so unit tests can inject an
/// ephemeral in-memory suite instead of polluting `.standard`. Production code
/// always uses the `shared` singleton, which calls `init()` → `init(store: .standard)`.
///
/// ## Thread safety
/// `@MainActor`-isolated. All `didSet` writes run on the main thread; no additional
/// synchronisation is needed.
@MainActor
@Observable
final class AppPreferencesStore {
    /// Shared singleton — use this instead of calling init directly.
    static let shared = AppPreferencesStore()

    /// UserDefaults key constants used by `AppPreferencesStore`.
    private enum Key {
        /// Key for the polling interval setting.
        static let pollingInterval = "settings.pollingInterval"
        /// Key for the show-dimmed-runners toggle.
        static let showDimmedRunners = "settings.showDimmedRunners"
        /// Key for the show-popover-arrow toggle.
        static let showPopoverArrow = "settings.showPopoverArrow"
    }

    /// Valid range for the polling interval in seconds. Minimum 10 s, maximum 300 s.
    static let pollingRange: ClosedRange<Int> = 10 ... 300

    // MARK: - Backing store

    /// The `UserDefaults` instance used for all reads and writes.
    /// Injected at init; defaults to `.standard` in production.
    private let defaults: UserDefaults

    // MARK: - Preferences

    /// How often (in seconds) RunnerBar polls GitHub. Clamped to 10–300 s.
    ///
    /// Setting this property out-of-range triggers a second `didSet` call with
    /// the clamped value — this re-entrancy is intentional and safe because
    /// `AppPreferencesStore` is `@MainActor`-isolated (all mutations are serialised
    /// on the main queue, so the recursive assignment cannot interleave).
    ///
    /// `RunnerStore` observes this `@Observable` property via
    /// `withObservationTracking`/`AsyncStream` and restarts its poll loop on change —
    /// no Combine subject bridge is required.
    var pollingInterval: Int {
        didSet {
            let clamped = pollingInterval.clamped(to: Self.pollingRange)
            if clamped != pollingInterval {
                pollingInterval = clamped
                return
            }
            defaults.set(pollingInterval, forKey: Key.pollingInterval)
        }
    }

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would break the stored key for
    /// users upgrading from older versions.
    var showDimmedRunners: Bool {
        didSet { defaults.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    /// Whether the NSPopover anchor arrow is shown.
    ///
    /// When `false`, the arrow is suppressed on the next popover open via the
    /// private-but-widely-used KVC key `shouldHideAnchor` on `NSPopover`.
    /// Default is `true` so existing users see no behaviour change on upgrade.
    ///
    /// Takes effect on the next `openPanel()` call — the arrow state is baked in
    /// at `popover.show()` time and cannot be changed mid-session.
    var showPopoverArrow: Bool {
        didSet { defaults.set(showPopoverArrow, forKey: Key.showPopoverArrow) }
    }

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    private convenience init() {
        self.init(store: .standard)
    }

    /// Designated initialiser.
    ///
    /// - Parameter store: The `UserDefaults` suite to read from and write to.
    ///   Pass `.standard` in production (via the `shared` singleton) or an
    ///   ephemeral suite (`UserDefaults(suiteName:)`) in unit tests to avoid
    ///   polluting the real preferences database. (P7)
    init(store: UserDefaults) {
        self.defaults = store
        store.register(defaults: [
            Key.pollingInterval: 15,  // First-launch default: 15 s (see #511)
            Key.showDimmedRunners: true,
            Key.showPopoverArrow: true,
        ])
        let stored = store.integer(forKey: Key.pollingInterval)
        pollingInterval = stored.clamped(to: Self.pollingRange)
        showDimmedRunners = store.bool(forKey: Key.showDimmedRunners)
        showPopoverArrow = store.bool(forKey: Key.showPopoverArrow)
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
