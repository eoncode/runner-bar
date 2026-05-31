// ScopeEntry.swift
// RunnerBarCore
import Foundation

// MARK: - ScopeEntry

/// A single watched GitHub scope (repo or org) with an enable/disable flag.
///
/// `scope` is either `"owner/repo"` (repository) or `"myorg"` (organisation).
/// `isEnabled` controls whether `RunnerStore` polls this scope; disabled scopes
/// are retained in the list but silently skipped during fetch.
public struct ScopeEntry: Identifiable, Codable, Equatable, Hashable {
    /// Stable identity for use in SwiftUI lists and `Codable` round-trips.
    public let id: UUID
    /// The GitHub scope string — either `"owner/repo"` or an org name.
    public var scope: String
    /// When `false`, `RunnerStore` skips this scope during polling.
    public var isEnabled: Bool

    /// Creates a new `ScopeEntry` with a fresh random `id`.
    /// - Parameters:
    ///   - scope: The GitHub scope string.
    ///   - isEnabled: Whether polling is active for this scope. Defaults to `true`.
    public init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
    }
}
