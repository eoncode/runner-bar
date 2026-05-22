import Combine
import Foundation

// MARK: - ScopeEntry

/// A single watched GitHub scope (repo or org) with an enable/disable flag.
///
/// `scope` is either `"owner/repo"` (repository) or `"myorg"` (organisation).
/// `isEnabled` controls whether `RunnerStore` polls this scope; disabled scopes
/// are retained in the list but silently skipped during fetch.
struct ScopeEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: String
    var isEnabled: Bool

    /// Convenience init with a new random ID and enabled by default.
    init(scope: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.scope = scope
        self.isEnabled = isEnabled
    }
}

// MARK: - ScopeStore

/// Persists the list of watched GitHub scopes as `[ScopeEntry]` in `UserDefaults`.
///
/// Migration: if the legacy `"scopes"` key (plain `[String]`) is present on first
/// launch it is converted to `[ScopeEntry]` (all enabled) and the old key is deleted.
///
/// Conforms to `ObservableObject` — SwiftUI views should use `@ObservedObject`.
/// Set `onMutate` to be notified after any structural change (add / remove).
final class ScopeStore: ObservableObject {
    /// Shared singleton — single source of truth for all scope operations.
    static let shared = ScopeStore()

    private let entriesKey = "scopeEntries"
    private let legacyKey = "scopes"

    /// Optional callback invoked after add or remove (not on toggle).
    var onMutate: (() -> Void)?

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

    /// `true` when no entries have been added yet.
    var isEmpty: Bool { entries.isEmpty }

    private init() {
        entries = loadEntries()
    }

    // MARK: - Persistence

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

    private func save(_ newEntries: [ScopeEntry]) {
        do {
            let data = try JSONEncoder().encode(newEntries)
            UserDefaults.standard.set(data, forKey: entriesKey)
            log("ScopeStore › saved \(newEntries.count) scope entry(ies)")
        } catch {
            log("ScopeStore › encode error: \(error)")
        }
    }

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
        onMutate?()
    }

    /// Removes the entry with the given ID. No-ops if not found.
    func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll(where: { $0.id == id })
        persist()
        log("ScopeStore › removed scope id: \(id)")
        onMutate?()
    }

    /// Legacy remove by scope string — kept for backward compatibility.
    func remove(_ scope: String) {
        guard let entry = entries.first(where: { $0.scope == scope }) else { return }
        remove(id: entry.id)
    }

    /// Toggles the `isEnabled` flag for the entry with the given ID.
    /// Does NOT invoke `onMutate` — enable/disable is not a structural change.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isEnabled = enabled
        persist()
        log("ScopeStore › scope \(entries[idx].scope) isEnabled=\(enabled)")
        // Publish so RunnerStore's Combine subscription triggers a polling restart.
        objectWillChange.send()
    }
}
