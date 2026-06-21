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

    /// Creates a new `ScopeEntry` with a fresh random `id`.
    /// - Parameters:
    ///   - scope: The GitHub scope string.
    ///   - isEnabled: Whether polling is active for this scope. Defaults to `true`.
    public init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
    }

    /// Identity-preserving init used by `copying(isEnabled:)`.
    /// Internal to avoid callers accidentally reusing an existing `id`.
    internal init(id: UUID, scope: String, isEnabled: Bool) {
        self.id = id
        self.scope = scope
        self.isEnabled = isEnabled
    }
}

// MARK: - Copy helpers

extension ScopeEntry {
    /// Returns a copy of this entry with `isEnabled` replaced, preserving `id` and `scope`.
    /// Use this instead of mutating `isEnabled` directly — the field is `let`.
    public func copying(isEnabled newValue: Bool) -> ScopeEntry {
        ScopeEntry(id: id, scope: scope, isEnabled: newValue)
    }
}
