// ScopeEntry.swift
// RunnerBar
import Foundation

// MARK: - ScopeEntry

/// A single watched GitHub scope (repo or org) with an enable/disable flag.
///
/// `scope` is either `"owner/repo"` (repository) or `"myorg"` (organisation).
/// `isEnabled` controls whether `RunnerStore` polls this scope; disabled scopes
/// are retained in the list but silently skipped during fetch.
struct ScopeEntry: Identifiable, Codable, Equatable {
    /// The id constant.
    let id: UUID
    /// The scope property.
    var scope: String
    /// The isEnabled property.
    var isEnabled: Bool

    /// Convenience init with a new random ID and enabled by default.
    init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
    }
}
