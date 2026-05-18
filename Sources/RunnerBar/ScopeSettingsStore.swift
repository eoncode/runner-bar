import Foundation

// MARK: - ScopeSettingsStore
// #505: Per-scope UserDefaults schema.
//
// Intentionally caseless — used as a namespace only. Instantiation is forbidden.
//
// Keys are namespaced under "scope.<scopeString>.<field>" so each scope has its
// own independent settings bucket. All values are optional — nil means "use the
// global setting" (alias: use raw scope string; polling: use SettingsStore.pollingInterval;
// notifications: use NotificationPrefsStore values).
//
// Call ScopeSettingsStore.cleanUp(scope:) from ScopeStore.remove(id:) to avoid
// orphaned keys accumulating in UserDefaults.

enum ScopeSettingsStore {
    // MARK: - Key builders

    private static func key(_ scope: String, _ field: String) -> String {
        "scope.\(scope).\(field)"
    }

    // MARK: - Alias (#500)

    /// Human-readable alias for this scope. `nil` = display raw scope string.
    static func alias(for scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope, "alias"))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setAlias(_ alias: String?, for scope: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = trimmed, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key(scope, "alias"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "alias"))
        }
        log("ScopeSettingsStore › alias for \(scope) = \(trimmed ?? "nil (cleared)")")
    }

    /// Display name: alias if set, otherwise the raw scope string.
    static func displayName(for scope: String) -> String {
        alias(for: scope) ?? scope
    }

    // MARK: - Polling interval override (#502)

    /// Per-scope polling interval in seconds. `nil` = use global `SettingsStore.pollingInterval`.
    static func pollingInterval(for scope: String) -> Int? {
        let stored = UserDefaults.standard.object(forKey: key(scope, "pollingInterval"))
        return stored as? Int
    }

    static func setPollingInterval(_ interval: Int?, for scope: String) {
        if let value = interval {
            UserDefaults.standard.set(value, forKey: key(scope, "pollingInterval"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "pollingInterval"))
        }
        log("ScopeSettingsStore › pollingInterval for \(scope) = \(interval.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - Notification overrides (#504)

    /// Per-scope notify-on-success override. `nil` = use global.
    static func notifyOnSuccess(for scope: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key(scope, "notifyOnSuccess")) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key(scope, "notifyOnSuccess"))
    }

    static func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
        if let v = value {
            UserDefaults.standard.set(v, forKey: key(scope, "notifyOnSuccess"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "notifyOnSuccess"))
        }
        log("ScopeSettingsStore › notifyOnSuccess for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    /// Per-scope notify-on-failure override. `nil` = use global.
    static func notifyOnFailure(for scope: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key(scope, "notifyOnFailure")) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key(scope, "notifyOnFailure"))
    }

    static func setNotifyOnFailure(_ value: Bool?, for scope: String) {
        if let v = value {
            UserDefaults.standard.set(v, forKey: key(scope, "notifyOnFailure"))
        } else {
            UserDefaults.standard.removeObject(forKey: key(scope, "notifyOnFailure"))
        }
        log("ScopeSettingsStore › notifyOnFailure for \(scope) = \(value.map(String.init) ?? "nil (use global)")")
    }

    // MARK: - Cleanup (#505)

    /// Removes all per-scope keys for `scope` from UserDefaults.
    /// Call this from `ScopeStore.remove(id:)` to avoid orphaned data.
    static func cleanUp(scope: String) {
        let fields = ["alias", "pollingInterval", "notifyOnSuccess", "notifyOnFailure"]
        for field in fields {
            UserDefaults.standard.removeObject(forKey: key(scope, field))
        }
        log("ScopeSettingsStore › cleaned up all keys for scope: \(scope)")
    }
}
