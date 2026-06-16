// ScopePreferencesStore.swift
// RunnerBarCore
import Foundation

// MARK: - ScopePreferencesStore

/// Namespace for per-scope `UserDefaults` preferences.
///
/// Intentionally caseless — used as a namespace only.
/// Keys are namespaced under `scope.<scope>.<field>` so each scope has its
/// own independent settings bucket. All values are optional — `nil` means
/// "use the global setting". Call `cleanUp(scope:)` from `ScopeStore.remove(id:)`
/// to avoid orphaned keys accumulating in `UserDefaults`.
public enum ScopePreferencesStore {

    // MARK: - Key builders

    /// Builds the `UserDefaults` key for a per-scope field.
    private static func key(_ scope: String, _ field: String) -> String {
        "scope.\(scope).\(field)"
    }

    // MARK: - Alias (#500)

    /// Human-readable alias for this scope. `nil` = display raw scope string.
    public static func alias(for scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, "alias"))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists a human-readable alias for a scope.
    public static func setAlias(_ alias: String?, for scope: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = trimmed, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key(scope, "alias"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "alias"))
        }
        log("ScopePreferencesStore › alias for \(scope) = \(trimmed ?? "nil (cleared)")")
    }

    /// Display name: alias if set, otherwise the raw scope string.
    public static func displayName(for scope: String) -> String {
        alias(for: scope) ?? scope
    }

    // MARK: - Polling interval override (#502)

    /// Per-scope polling interval in seconds. `nil` = use global `SettingsStore.pollingInterval`.
    public static func pollingInterval(for scope: String) -> Int? {
        let stored = UserDefaults.standard.object(forKey: key(scope, "pollingInterval"))
        return stored as? Int
    }

    /// Persists a per-scope polling-interval override.
    public static func setPollingInterval(_ interval: Int?, for scope: String) {
        if let value = interval {
            UserDefaults.standard.set(value, forKey: key(scope, "pollingInterval"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "pollingInterval"))
        }
        log("ScopePreferencesStore › pollingInterval for \(scope) = \(interval.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - Notification overrides (#504)

    /// Per-scope notify-on-success override. `nil` = use global.
    public static func notifyOnSuccess(for scope: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key(scope, "notifyOnSuccess")) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key(scope, "notifyOnSuccess"))
    }

    /// Persists a per-scope notify-on-success override.
    public static func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
        if let value = value {
            UserDefaults.standard.set(value, forKey: key(scope, "notifyOnSuccess"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "notifyOnSuccess"))
        }
        log("ScopePreferencesStore › notifyOnSuccess for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    /// Per-scope notify-on-failure override. `nil` = use global.
    public static func notifyOnFailure(for scope: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key(scope, "notifyOnFailure")) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key(scope, "notifyOnFailure"))
    }

    /// Persists a per-scope notify-on-failure override.
    public static func setNotifyOnFailure(_ value: Bool?, for scope: String) {
        if let value = value {
            UserDefaults.standard.set(value, forKey: key(scope, "notifyOnFailure"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "notifyOnFailure"))
        }
        log("ScopePreferencesStore › notifyOnFailure for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - Failure Hook (#544)

    /// Whether the failure hook is enabled for this scope.
    public static func failureHookEnabled(for scope: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(scope, "failureHookEnabled"))
    }

    /// Persists whether the failure hook is enabled for a scope.
    public static func setFailureHookEnabled(_ enabled: Bool, for scope: String) {
        UserDefaults.standard.set(enabled, forKey: key(scope, "failureHookEnabled"))
        log("ScopePreferencesStore › failureHookEnabled for \(scope) = \(enabled)")
    }

    /// The shell command to run on failure. `nil` = no command set.
    public static func failureHookCommand(for scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, "failureHookCommand"))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists the shell command to run when a failure hook fires.
    public static func setFailureHookCommand(_ command: String?, for scope: String) {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = trimmed, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key(scope, "failureHookCommand"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "failureHookCommand"))
        }
        log("ScopePreferencesStore › failureHookCommand for \(scope) = \(trimmed ?? "nil (cleared)")")
    }

    /// Local filesystem path to the repo for this scope. `nil` = not set.
    public static func localRepoPath(for scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, "localRepoPath"))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists the local repository path used for this scope’s failure hook.
    public static func setLocalRepoPath(_ path: String?, for scope: String) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = trimmed, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key(scope, "localRepoPath"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "localRepoPath"))
        }
        log("ScopePreferencesStore › localRepoPath for \(scope) = \(trimmed ?? "nil (cleared)")")
    }

    // MARK: - Failure Hook Branch Filter (#560)

    /// Branch to restrict the failure hook to. `nil` = fire for all branches.
    public static func failureHookBranch(for scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, "failureHookBranch"))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists the branch filter used by the failure hook.
    public static func setFailureHookBranch(_ branch: String?, for scope: String) {
        if let value = branch, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key(scope, "failureHookBranch"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "failureHookBranch"))
        }
        log("ScopePreferencesStore › failureHookBranch for \(scope) = \(branch ?? "nil (all branches)")")
    }

    // MARK: - Cleanup (#505)

    /// Removes all per-scope `UserDefaults` keys for the given scope.
    /// Call from `ScopeStore.remove(id:)` to avoid orphaned data accumulating.
    public static func cleanUp(scope: String) {
        let fields = [
            "alias",
            "pollingInterval",
            "notifyOnSuccess",
            "notifyOnFailure",
            "failureHookEnabled",
            "failureHookCommand",
            "localRepoPath",
            "failureHookBranch"
        ]
        for field in fields {
            UserDefaults.standard.removeObject(forKey: key(scope, field))
        }
        log("ScopePreferencesStore › cleaned up all keys for scope: \(scope)")
    }
}
