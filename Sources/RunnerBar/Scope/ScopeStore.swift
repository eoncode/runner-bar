// ScopeStore.swift
// RunnerBar
// swiftlint:disable orphaned_doc_comment
import Combine
import Foundation

// MARK: - ScopeStore

/// Persists the list of watched GitHub scopes as `[ScopeEntry]` in `UserDefaults`.
///
/// Migration: if the legacy `"scopes"` key (plain `[String]`) is present on first
/// launch it is converted to `[ScopeEntry]` (all enabled) and the old key is deleted.
///
/// Conforms to `ObservableObject` — SwiftUI views should use `@ObservedObject`.
/// Subscribe to `didMutate` to be notified after any structural change (add / remove).
final class ScopeStore: ObservableObject {
    /// Shared singleton — single source of truth for all scope operations.
    static let shared = ScopeStore()

    /// The entriesKey constant.
    private let entriesKey = "scopeEntries"
    /// The legacyKey constant.
    private let legacyKey = "scopes"

    /// Emits after every structural mutation (add / remove). Callers subscribe and
    /// store the resulting `AnyCancellable`. Using a subject instead of a plain
    /// optional closure avoids any risk of a retain cycle at the call site.
    let didMutate = PassthroughSubject<Void, Never>()

    /// All scope entries, persisted as JSON in `UserDefaults`.
    /// Publishes `objectWillChange` before every write so observing views update.
    @Published private(set) var entries: [ScopeEntry] = [] {
        willSet { objectWillChange.send() }
    }

    /// Scopes that are currently enabled — used by `RunnerStore` for polling.
    var activeScopes: [String] { entries.filter(\.isEnabled).map(\.scope) }

    /// Legacy accessor: all scope strings regardless of enabled state.
    /// Kept for call-sites not yet migrated; prefer `activeScopes`.
    var scopes: [String] { entries.map(\.scope) }

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
            let decoded = try JSONDecoder().decode([ScopeEntry].self, from: data)
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
            let data = try JSONEncoder().encode(newEntries)
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
        didMutate.send()
    }

    /// Removes the entry with the given ID. No-ops if not found.
    func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll(where: { $0.id == id })
        persist()
        log("ScopeStore › removed scope id: \(id)")
        didMutate.send()
    }

    /// Toggles the `isEnabled` flag for the entry with the given ID.
    /// Does NOT send `didMutate` — enable/disable is not a structural change.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isEnabled = enabled
        persist()
        log("ScopeStore › scope \(entries[idx].scope) isEnabled=\(enabled)")
        // Publish so RunnerStore's Combine subscription triggers a polling restart.
        objectWillChange.send()
    }
}
// swiftlint:enable orphaned_doc_comment
