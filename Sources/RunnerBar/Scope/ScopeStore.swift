// ScopeStore.swift
// RunnerBar
import Foundation
import Observation

// MARK: - ScopeStore

/// Persists the list of watched GitHub scopes as `[ScopeEntry]` in `UserDefaults`.
///
/// Migration: if the legacy `"scopes"` key (plain `[String]`) is present on first
/// launch it is converted to `[ScopeEntry]` (all enabled) and the old key is deleted.
///
/// Mutations update the `@Observable` `entries` array; `RunnerStore` observes
/// `activeScopes` via `withObservationTracking`/`AsyncStream` (no Combine bridge).
@MainActor
@Observable
final class ScopeStore {
    /// Shared singleton — single source of truth for all scope operations.
    static let shared = ScopeStore()

    /// Shared `JSONDecoder` — reused across all `load()` calls instead of per-call instantiation.
    private let decoder = JSONDecoder()
    /// Shared `JSONEncoder` — reused across all `save()` calls instead of per-call instantiation.
    private let encoder = JSONEncoder()

    /// `UserDefaults` key for the JSON-encoded `[ScopeEntry]` array.
    private let entriesKey = "scopeEntries"
    /// `UserDefaults` key for the legacy plain `[String]` scopes array, kept for migration only.
    private let legacyKey = "scopes"

    /// All scope entries, persisted as JSON in `UserDefaults`.
    /// `private(set)` — mutate only through the designated methods on this type
    /// (`add(_:)`, `remove(id:)`, `setEnabled(_:_:)`). `load()` via `init()` is
    /// the only other write path; it assigns during initialisation only.
    private(set) var entries: [ScopeEntry] = []

    /// Scopes that are currently enabled — used by `RunnerStore` for polling.
    var activeScopes: [String] { entries.filter(\.isEnabled).map(\.scope) }

    /// Initialises the store by loading persisted entries (or migrating the
    /// legacy `[String]` key if present).
    private init() {
        entries = loadEntries()
    }

    // MARK: - Persistence

    /// Loads `[ScopeEntry]` from `UserDefaults`, migrating the legacy
    /// `[String]` key when found. Returns an empty array on decode failure.
    private func loadEntries() -> [ScopeEntry] {
        // Migration: convert legacy [String] key if present.
        if let legacy = UserDefaults.standard.stringArray(forKey: legacyKey),
           !legacy.isEmpty {
            log("ScopeStore › migrating \(legacy.count) legacy scope(s) to ScopeEntry")
            let migrated = legacy.map { ScopeEntry(scope: $0, isEnabled: true) }
            save(migrated)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return migrated
        }
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else {
            log("ScopeStore › no stored entries found")
            return []
        }
        do {
            let decoded = try decoder.decode([ScopeEntry].self, from: data)
            log("ScopeStore › loaded \(decoded.count) scope entry(ies)")
            return decoded
        } catch {
            log("ScopeStore › decode error: \(error) — returning empty")
            return []
        }
    }

    /// JSON-encodes `newEntries` and writes them to `UserDefaults`.
    /// Logs an error and no-ops when encoding fails.
    /// - Parameter newEntries: The complete list of entries to persist.
    private func save(_ newEntries: [ScopeEntry]) {
        do {
            let data = try encoder.encode(newEntries)
            UserDefaults.standard.set(data, forKey: entriesKey)
            log("ScopeStore › saved \(newEntries.count) scope entry(ies)")
        } catch {
            log("ScopeStore › encode error: \(error)")
        }
    }

    /// Persists the current in-memory `entries` array to `UserDefaults`.
    private func persist() { save(entries) }

    // MARK: - Mutations

    /// Appends a new enabled entry after trimming whitespace.
    /// No-ops if empty or if `scope` already exists (any case).
    func add(_ scope: String) {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !entries.contains(where: { $0.scope == trimmed }) else { return }
        entries.append(ScopeEntry(scope: trimmed))
        persist()
        log("ScopeStore › added scope: \(trimmed)")
    }

    /// Removes the entry with the entry with the given ID. No-ops if not found.
    func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll(where: { $0.id == id })
        persist()
        log("ScopeStore › removed scope id: \(id)")
    }

    /// Toggles the `isEnabled` flag for the entry with the given ID and persists
    /// the change. `RunnerStore` observes `activeScopes` via `withObservationTracking`,
    /// so replacing the element in the `@Observable` `entries` array triggers a
    /// poll-loop restart.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx] = entries[idx].copying(isEnabled: enabled)
        persist()
        // Log the committed value from the array, not the argument, so the log
        // remains accurate if copying(isEnabled:) ever gains filtering logic.
        log("ScopeStore › scope \(entries[idx].scope) isEnabled=\(entries[idx].isEnabled)")
    }
}
