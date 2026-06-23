// ScopePreferencesStore.swift
// RunnerBarCore
import Foundation

// MARK: - ScopePreferencesStore

/// Actor that owns all `UserDefaults` read/write for per-scope preferences.
///
/// Preferences are serialised as a single `ScopePreferences` JSON blob per scope
/// under the key `scope.<scope>.preferences`. This replaces the legacy flat-key
/// scheme (`scope.<scope>.<field>`) used by the caseless-enum predecessor.
///
/// ## Why one blob per scope?
/// A single JSON blob means `cleanUp(scope:)` is one `removeObject(forKey:)` call
/// with no hardcoded field list to maintain. Adding a new field to `ScopePreferences`
/// automatically includes it in cleanup without touching this file.
///
/// ## Migration
/// Call `migrateIfNeeded(knownScopes:)` once from `AppDelegate.applicationDidFinishLaunching`
/// before any reads occur. It reads the legacy flat keys, writes the blob, removes
/// the flat keys, and sets a `scope.__migrated_v2` guard flag. Safe to call multiple times.
///
/// ## Encoder/decoder reuse (P17)
/// `decoder` and `encoder` are `nonisolated` — `JSONDecoder`/`JSONEncoder` have no
/// mutable state after initialisation and are safe to access from `nonisolated` contexts.
/// `UserDefaults` operations are fast, in-process, and synchronous, so `@concurrent`
/// is not needed here (unlike `RunnerConfigStore` which does blocking disk I/O).
///
/// ## P21 note
/// `JSONEncoder.outputFormatting` is intentionally NOT set to `.prettyPrinted`/`.sortedKeys`
/// here. P21 applies to agent-managed config files that are diffed in git between RunnerBar
/// and the GitHub Actions runner agent. `UserDefaults` blobs are opaque binary plist data
/// and are never inspected as text, so human-readable formatting is not applicable.
public actor ScopePreferencesStore: ScopePreferencesStoreProtocol {

    // MARK: - Shared instance

    /// The shared singleton — use this in production; pass `init(store:)` in tests.
    public static let shared = ScopePreferencesStore()

    // MARK: - Private state

    private let store: UserDefaults

    /// Reused decoder. `nonisolated` because `JSONDecoder` is immutable post-init (P17).
    nonisolated private let decoder = JSONDecoder()
    /// Reused encoder. `nonisolated` because `JSONEncoder` is immutable post-init (P17).
    nonisolated private let encoder = JSONEncoder()

    // MARK: - Init

    /// Creates a store backed by `store`.
    /// - Parameter store: `UserDefaults` instance to read/write. Defaults to `.standard`;
    ///   pass a suite instance in tests to avoid polluting real defaults. (P7, P3)
    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    // MARK: - Key helpers

    private func blobKey(for scope: String) -> String {
        "scope.\(scope).preferences"
    }

    // MARK: - Internal read/write

    /// Reads the stored `ScopePreferences` for `scope`, returning defaults if absent or undecodable.
    private func read(scope: String) -> ScopePreferences {
        guard
            let data = store.data(forKey: blobKey(for: scope)),
            let prefs = try? decoder.decode(ScopePreferences.self, from: data)
        else { return ScopePreferences() }
        return prefs
    }

    /// Encodes and writes `prefs` for `scope`.
    ///
    /// `JSONEncoder` encoding a flat `Codable` struct of `String?/Bool/Int?` fields
    /// cannot realistically fail. If it ever does (e.g. OOM), the failure is logged
    /// and the write is a no-op — the stored blob simply retains its previous value.
    /// `throws` is intentionally absent: surfacing an error here would require
    /// changing all `setXxx` protocol signatures to `throws` with no practical benefit.
    private func write(_ prefs: ScopePreferences, for scope: String) {
        guard let data = try? encoder.encode(prefs) else {
            log("ScopePreferencesStore › encode failed for scope: \(scope) — write skipped")
            return
        }
        store.set(data, forKey: blobKey(for: scope))
        log("ScopePreferencesStore › saved preferences for \(scope)")
    }

    // MARK: - ScopePreferencesStoreProtocol — bulk snapshot

    /// Returns the full `ScopePreferences` snapshot for `scope` in a single actor hop.
    ///
    /// This is the preferred read path when multiple fields are needed at once
    /// (e.g. seeding `ScopeEditSheet` draft state). One `await` instead of N.
    public func preferences(for scope: String) -> ScopePreferences {
        read(scope: scope)
    }

    // MARK: - ScopePreferencesStoreProtocol — alias

    public func alias(for scope: String) -> String? {
        read(scope: scope).alias.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setAlias(_ alias: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.alias = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › alias for \(scope) = \(prefs.alias ?? "nil (cleared)")")
    }

    public func displayName(for scope: String) -> String {
        alias(for: scope) ?? scope
    }

    // MARK: - ScopePreferencesStoreProtocol — polling interval

    public func pollingInterval(for scope: String) -> Int? {
        read(scope: scope).pollingInterval
    }

    public func setPollingInterval(_ interval: Int?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.pollingInterval = interval
        write(prefs, for: scope)
        log("ScopePreferencesStore › pollingInterval for \(scope) = \(interval.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — notification overrides

    public func notifyOnSuccess(for scope: String) -> Bool? {
        read(scope: scope).notifyOnSuccess
    }

    public func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.notifyOnSuccess = value
        write(prefs, for: scope)
        log("ScopePreferencesStore › notifyOnSuccess for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    public func notifyOnFailure(for scope: String) -> Bool? {
        read(scope: scope).notifyOnFailure
    }

    public func setNotifyOnFailure(_ value: Bool?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.notifyOnFailure = value
        write(prefs, for: scope)
        log("ScopePreferencesStore › notifyOnFailure for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — failure hook

    public func failureHookEnabled(for scope: String) -> Bool {
        read(scope: scope).failureHookEnabled
    }

    public func setFailureHookEnabled(_ enabled: Bool, for scope: String) {
        var prefs = read(scope: scope)
        prefs.failureHookEnabled = enabled
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookEnabled for \(scope) = \(enabled)")
    }

    public func failureHookCommand(for scope: String) -> String? {
        read(scope: scope).failureHookCommand.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setFailureHookCommand(_ command: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.failureHookCommand = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookCommand for \(scope) = \(prefs.failureHookCommand ?? "nil (cleared)")")
    }

    public func localRepoPath(for scope: String) -> String? {
        read(scope: scope).localRepoPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setLocalRepoPath(_ path: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.localRepoPath = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › localRepoPath for \(scope) = \(prefs.localRepoPath ?? "nil (cleared)")")
    }

    public func failureHookBranch(for scope: String) -> String? {
        read(scope: scope).failureHookBranch.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setFailureHookBranch(_ branch: String?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.failureHookBranch = (branch?.isEmpty == false) ? branch : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookBranch for \(scope) = \(prefs.failureHookBranch ?? "nil (all branches)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — cleanup

    public func cleanUp(scope: String) {
        store.removeObject(forKey: blobKey(for: scope))
        log("ScopePreferencesStore › cleaned up all keys for scope: \(scope)")
    }

    // MARK: - Migration

    private static let migrationKey = "scope.__migrated_v2"

    /// Migrates legacy flat `UserDefaults` keys to the single-blob format.
    ///
    /// Reads each legacy `scope.<scope>.<field>` key, assembles a `ScopePreferences`
    /// value, writes the blob, then removes the flat keys. Guarded by a
    /// `scope.__migrated_v2` flag so it is safe to call multiple times.
    ///
    /// Call this from `AppDelegate.applicationDidFinishLaunching` (via
    /// `AppDelegate+StoreSetup`) before any other reads occur. (Step 7)
    ///
    /// - Parameter knownScopes: The list of scope strings currently in `ScopeStore`.
    ///   Only scopes in this list are migrated — scopes removed before migration
    ///   will have their legacy keys cleaned up on the next `cleanUp(scope:)` call
    ///   (which also removes the blob key, a no-op for unmigrated scopes).
    public func migrateIfNeeded(knownScopes: [String]) {
        guard !store.bool(forKey: Self.migrationKey) else { return }
        for scope in knownScopes {
            var prefs = ScopePreferences()
            if let v = store.string(forKey: "scope.\(scope).alias"), !v.isEmpty {
                prefs.alias = v
            }
            if let v = store.object(forKey: "scope.\(scope).pollingInterval") as? Int {
                prefs.pollingInterval = v
            }
            if store.object(forKey: "scope.\(scope).notifyOnSuccess") != nil {
                prefs.notifyOnSuccess = store.bool(forKey: "scope.\(scope).notifyOnSuccess")
            }
            if store.object(forKey: "scope.\(scope).notifyOnFailure") != nil {
                prefs.notifyOnFailure = store.bool(forKey: "scope.\(scope).notifyOnFailure")
            }
            prefs.failureHookEnabled = store.bool(forKey: "scope.\(scope).failureHookEnabled")
            if let v = store.string(forKey: "scope.\(scope).failureHookCommand"), !v.isEmpty {
                prefs.failureHookCommand = v
            }
            if let v = store.string(forKey: "scope.\(scope).localRepoPath"), !v.isEmpty {
                prefs.localRepoPath = v
            }
            if let v = store.string(forKey: "scope.\(scope).failureHookBranch"), !v.isEmpty {
                prefs.failureHookBranch = v
            }
            write(prefs, for: scope)
            for field in ["alias", "pollingInterval", "notifyOnSuccess", "notifyOnFailure",
                          "failureHookEnabled", "failureHookCommand", "localRepoPath", "failureHookBranch"] {
                store.removeObject(forKey: "scope.\(scope).\(field)")
            }
        }
        store.set(true, forKey: Self.migrationKey)
        log("ScopePreferencesStore › migration v2 complete for \(knownScopes.count) scopes")
    }
}
