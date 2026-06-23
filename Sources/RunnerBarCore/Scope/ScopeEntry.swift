// ScopeEntry.swift
// RunnerBarCore
import Foundation

// MARK: - ScopeEntry

/// A single watched GitHub scope (repo or org) with an enable/disable flag.
///
/// `scope` is either `"owner/repo"` (repository) or `"myorg"` (organisation).
/// `isEnabled` controls whether `RunnerStore` polls this scope; disabled scopes
/// are retained in the list but silently skipped during fetch.
public struct ScopeEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable identity for use in SwiftUI lists and `Codable` round-trips.
    public let id: UUID
    /// The GitHub scope string — either `"owner/repo"` or an org name.
    /// `let`: the scope string is immutable after construction. To change a scope,
    /// remove the existing entry and add a new one via `ScopeStore`.
    public let scope: String
    /// When `false`, `RunnerStore` skips this scope during polling.
    /// `let`: use `copying(isEnabled:)` to derive a toggled copy — the only intended
    /// mutation site is `ScopeStore.setEnabled(_:_:)`.
    public let isEnabled: Bool
    /// Cached alias for this scope, populated by `ScopeStore.refreshDisplayNames()`
    /// from `ScopePreferencesStore`. `nil` when no alias has been set.
    /// Not persisted to `UserDefaults` — always re-hydrated at launch and after edits.
    /// Excluded from `Codable` synthesis via `CodingKeys` below.
    public let displayName: String?

    // MARK: - CodingKeys (excludes transient displayName)

    /// Explicit coding keys so that `displayName` is never written to or read from
    /// the persisted `UserDefaults` blob — it is always re-hydrated at runtime.
    enum CodingKeys: String, CodingKey {
        /// Stable UUID identity.
        case id
        /// The GitHub scope string.
        case scope
        /// Whether polling is active for this scope.
        case isEnabled
    }

    /// Creates a new `ScopeEntry` with a fresh random `id` and no display name.
    /// - Parameters:
    ///   - scope: The GitHub scope string.
    ///   - isEnabled: Whether polling is active for this scope. Defaults to `true`.
    public init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
        self.displayName = nil
    }

    /// Identity-preserving init used exclusively by `copying(isEnabled:)` and
    /// `copying(displayName:)`. Accepts an explicit `id` so that `copying` returns
    /// a value with the same stable identity as the original — required for correct
    /// SwiftUI list diffing and lossless `Codable` round-trips.
    private init(id: UUID, scope: String, isEnabled: Bool, displayName: String?) {
        self.id = id
        self.scope = scope
        self.isEnabled = isEnabled
        self.displayName = displayName
    }

    /// Decodes a persisted `ScopeEntry`. `displayName` is transient and always
    /// initialised to `nil` — `ScopeStore.refreshDisplayNames()` re-hydrates it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        scope = try container.decode(String.self, forKey: .scope)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        displayName = nil
    }
}

// MARK: - Copy helpers

/// Helpers for deriving immutable `ScopeEntry` copies with a single field replaced.
/// Follows the same `copying(…)` pattern used by `ActiveJob` and `RunnerModel`.
extension ScopeEntry {
    /// Returns a copy of this entry with `isEnabled` replaced, preserving all other fields.
    /// Use this instead of mutating `isEnabled` directly — the field is `let`.
    public func copying(isEnabled newValue: Bool) -> ScopeEntry {
        ScopeEntry(id: id, scope: scope, isEnabled: newValue, displayName: displayName)
    }

    /// Returns a copy of this entry with `displayName` replaced, preserving all other fields.
    /// Used by `ScopeStore.refreshDisplayNames()` to hydrate aliases from `ScopePreferencesStore`.
    public func copying(displayName newValue: String?) -> ScopeEntry {
        ScopeEntry(id: id, scope: scope, isEnabled: isEnabled, displayName: newValue)
    }
}
