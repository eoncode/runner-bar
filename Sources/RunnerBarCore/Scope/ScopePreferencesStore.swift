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
/// A single JSON blob means `cleanUp(scope:)` removes the blob key *and* any
/// surviving legacy flat keys in one call. Adding a new field to `ScopePreferences`
/// automatically includes it in cleanup without touching this file.
///
/// ## Migration
/// Call `migrateIfNeeded(knownScopes:)` once from `AppDelegate.applicationDidFinishLaunching`
/// before any reads occur. It reads the legacy flat keys, writes the blob, removes
/// the flat keys, and sets a `scope.__migrated_v2` guard flag. Safe to call multiple times.
///
/// ## Encoder/decoder (P17)
/// `decoder` and `encoder` are plain `private let` stored properties — not `nonisolated`.
/// They are only ever called from actor-isolated `read` and `write`, which are serialised
/// by the actor's executor, so there is no concurrent access. Dropping `nonisolated`
/// removes any theoretical exposure to non-isolated call sites and avoids relying on
/// the undocumented thread-safety of `JSONDecoder`/`JSONEncoder`.
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

    /// The underlying `UserDefaults` instance used for all read/write operations.
    private let store: UserDefaults

    /// Reused decoder. Private (not nonisolated) — only called from actor-isolated
    /// `read(_:)`, so the actor's serial executor prevents concurrent access. (P17)
    private let decoder = JSONDecoder()
    /// Reused encoder. Private (not nonisolated) — only called from actor-isolated
    /// `write(_:for:)`, so the actor's serial executor prevents concurrent access. (P17)
    private let encoder = JSONEncoder()

    // MARK: - Legacy flat-key field list

    /// The complete set of flat-key suffixes used by the pre-migration scheme.
    ///
    /// Kept as a single source of truth so both `migrateIfNeeded` and `cleanUp`
    /// use the same list. If a new field is ever added here it will automatically
    /// be cleaned up by both call sites.
    private static let legacyFields = [
        "alias", "pollingInterval", "notifyOnSuccess", "notifyOnFailure",
        "failureHookEnabled", "failureHookCommand", "localRepoPath", "failureHookBranch"
    ]

    // MARK: - Init

    /// Creates a store backed by `store`.
    /// - Parameter store: `UserDefaults` instance to read/write. Defaults to `.standard`;
    ///   pass a suite instance in tests to avoid polluting real defaults. (P7, P3)
    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    // MARK: - Key helpers

    /// Returns the `UserDefaults` key for the JSON blob of the given scope.
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

    // MARK: - ScopePreferencesStoreProtocol — bulk snapshot / write

    /// Returns the full `ScopePreferences` snapshot for `scope` in a single actor hop.
    ///
    /// This is the preferred read path when multiple fields are needed at once
    /// (e.g. seeding `ScopeEditSheet` draft state). One `await` instead of N.
    public func preferences(for scope: String) -> ScopePreferences {
        read(scope: scope)
    }

    /// Writes a complete `ScopePreferences` snapshot for `scope` in a single actor hop.
    ///
    /// This is the preferred write path when multiple fields need to be committed
    /// atomically (e.g. `ScopeEditSheet.confirmSave()`). One `await` and one
    /// encode/write instead of N sequential read-modify-write cycles.
    public func setPreferences(_ prefs: ScopePreferences, for scope: String) {
        write(prefs, for: scope)
    }

    // MARK: - ScopePreferencesStoreProtocol — alias

    /// Returns the stored alias for `scope`, or `nil` if unset or empty.
    public func alias(for scope: String) -> String? {
        read(scope: scope).alias.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists a trimmed alias for `scope`; passes `nil` or empty string to clear.
    public func setAlias(_ alias: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.alias = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › alias for \(scope) = \(prefs.alias ?? "nil (cleared)")")
    }

    /// Returns the alias for `scope` if set, otherwise the raw scope string.
    public func displayName(for scope: String) -> String {
        alias(for: scope) ?? scope
    }

    // MARK: - ScopePreferencesStoreProtocol — polling interval

    /// Returns the per-scope polling interval override, or `nil` to use the global default.
    public func pollingInterval(for scope: String) -> Int? {
        read(scope: scope).pollingInterval
    }

    /// Stores a per-scope polling interval override for `scope`; pass `nil` to revert to the global default.
    public func setPollingInterval(_ interval: Int?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.pollingInterval = interval
        write(prefs, for: scope)
        log("ScopePreferencesStore › pollingInterval for \(scope) = \(interval.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — notification overrides

    /// Returns the per-scope success-notification override, or `nil` to use the global setting.
    public func notifyOnSuccess(for scope: String) -> Bool? {
        read(scope: scope).notifyOnSuccess
    }

    /// Stores a per-scope success-notification override; pass `nil` to revert to the global setting.
    public func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.notifyOnSuccess = value
        write(prefs, for: scope)
        log("ScopePreferencesStore › notifyOnSuccess for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    /// Returns the per-scope failure-notification override, or `nil` to use the global setting.
    public func notifyOnFailure(for scope: String) -> Bool? {
        read(scope: scope).notifyOnFailure
    }

    /// Stores a per-scope failure-notification override; pass `nil` to revert to the global setting.
    public func setNotifyOnFailure(_ value: Bool?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.notifyOnFailure = value
        write(prefs, for: scope)
        log("ScopePreferencesStore › notifyOnFailure for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — failure hook

    /// Returns whether the failure hook script is enabled for `scope`.
    public func failureHookEnabled(for scope: String) -> Bool {
        read(scope: scope).failureHookEnabled
    }

    /// Enables or disables the failure hook script for `scope`.
    public func setFailureHookEnabled(_ enabled: Bool, for scope: String) {
        var prefs = read(scope: scope)
        prefs.failureHookEnabled = enabled
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookEnabled for \(scope) = \(enabled)")
    }

    /// Returns the shell command to run on failure for `scope`, or `nil` if unset.
    public func failureHookCommand(for scope: String) -> String? {
        read(scope: scope).failureHookCommand.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Stores the failure hook shell command for `scope`; pass `nil` or empty string to clear.
    public func setFailureHookCommand(_ command: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.failureHookCommand = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookCommand for \(scope) = \(prefs.failureHookCommand ?? "nil (cleared)")")
    }

    /// Returns the local repository path override for `scope`, or `nil` if unset.
    public func localRepoPath(for scope: String) -> String? {
        read(scope: scope).localRepoPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Stores the local repository path for `scope`; pass `nil` or empty string to clear.
    public func setLocalRepoPath(_ path: String?, for scope: String) {
        var prefs = read(scope: scope)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.localRepoPath = (trimmed?.isEmpty == false) ? trimmed : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › localRepoPath for \(scope) = \(prefs.localRepoPath ?? "nil (cleared)")")
    }

    /// Returns the branch filter for the failure hook for `scope`, or `nil` to run on all branches.
    public func failureHookBranch(for scope: String) -> String? {
        read(scope: scope).failureHookBranch.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Stores the branch filter for the failure hook for `scope`; pass `nil` to run on all branches.
    public func setFailureHookBranch(_ branch: String?, for scope: String) {
        var prefs = read(scope: scope)
        prefs.failureHookBranch = (branch?.isEmpty == false) ? branch : nil
        write(prefs, for: scope)
        log("ScopePreferencesStore › failureHookBranch for \(scope) = \(prefs.failureHookBranch ?? "nil (all branches)")")
    }

    // MARK: - ScopePreferencesStoreProtocol — cleanup

    /// Removes all persisted data for `scope`: the blob key and any surviving
    /// legacy flat keys.
    ///
    /// The legacy flat-key removal handles the edge case where a scope existed in the
    /// old flat-key format but was removed from `ScopeStore` before `migrateIfNeeded`
    /// ran — those keys would otherwise be orphaned indefinitely in `UserDefaults`.
    /// For post-migration scopes the flat-key removals are no-ops.
    /// Removes the stored preferences blob for `scope` from `UserDefaults`.
    public func cleanUp(scope: String) {
        store.removeObject(forKey: blobKey(for: scope))
        for field in Self.legacyFields {
            store.removeObject(forKey: "scope.\(scope).\(field)")
        }
        log("ScopePreferencesStore › cleaned up all keys for scope: \(scope)")
    }

    // MARK: - Migration

    /// `UserDefaults` flag set after a successful v2 migration; guards against re-running migration.
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
    ///   Only scopes in this list are migrated. Scopes added after this flag is set
    ///   start clean (no legacy flat keys), so skipping them in future calls is
    ///   intentional. Scopes removed before migration ran will have their legacy keys
    ///   cleaned up by `cleanUp(scope:)` if they are ever explicitly removed, or they
    ///   will remain as inert orphan keys — this is an accepted low-severity trade-off.
    public func migrateIfNeeded(knownScopes: [String]) {
        guard !store.bool(forKey: Self.migrationKey) else {
            // Migration already ran. Scopes added after this point start clean
            // (no legacy flat keys) so skipping them here is intentional.
            return
        }
        for scope in knownScopes {
            var prefs = ScopePreferences()
            if let val = store.string(forKey: "scope.\(scope).alias"), !val.isEmpty {
                prefs.alias = val
            }
            if let val = store.object(forKey: "scope.\(scope).pollingInterval") as? Int {
                prefs.pollingInterval = val
            }
            if store.object(forKey: "scope.\(scope).notifyOnSuccess") != nil {
                prefs.notifyOnSuccess = store.bool(forKey: "scope.\(scope).notifyOnSuccess")
            }
            if store.object(forKey: "scope.\(scope).notifyOnFailure") != nil {
                prefs.notifyOnFailure = store.bool(forKey: "scope.\(scope).notifyOnFailure")
            }
            prefs.failureHookEnabled = store.bool(forKey: "scope.\(scope).failureHookEnabled")
            if let val = store.string(forKey: "scope.\(scope).failureHookCommand"), !val.isEmpty {
                prefs.failureHookCommand = val
            }
            if let val = store.string(forKey: "scope.\(scope).localRepoPath"), !val.isEmpty {
                prefs.localRepoPath = val
            }
            if let val = store.string(forKey: "scope.\(scope).failureHookBranch"), !val.isEmpty {
                prefs.failureHookBranch = val
            }
            write(prefs, for: scope)
            for field in Self.legacyFields {
                store.removeObject(forKey: "scope.\(scope).\(field)")
            }
        }
        store.set(true, forKey: Self.migrationKey)
        log("ScopePreferencesStore › migration v2 complete for \(knownScopes.count) scopes")
    }
}
