// ScopePreferencesStoreProtocol.swift
// RunnerBarCore

// MARK: - ScopePreferencesStoreProtocol

/// Abstraction over per-scope preferences persistence.
///
/// Marked `@MainActor` because all current consumers (`ScopeEditSheet`,
/// `SettingsView`, `ScopesView`) are `@MainActor`-bound SwiftUI views.
/// This makes the isolation contract explicit and compiler-enforced (P4)
/// rather than relying on call-site discipline.
///
/// The protocol surface is intentionally minimal: read a full `ScopePreferences`
/// snapshot, write a full snapshot, and resolve a display name. This replaces
/// the previous 10-method static API on `ScopePreferencesStore` with a typed,
/// atomic read/write contract (P3).
@MainActor
public protocol ScopePreferencesStoreProtocol: AnyObject {

    /// Returns the current preferences snapshot for a scope.
    func preferences(for scope: String) -> ScopePreferences

    /// Atomically persists a full preferences snapshot for a scope.
    func setPreferences(_ prefs: ScopePreferences, for scope: String)

    /// Display name: alias if set, otherwise the raw scope string.
    func displayName(for scope: String) -> String
}
