import Foundation

/// Persists the list of watched GitHub scopes (e.g. `"owner/repo"` or `"myorg"`).
///
/// A scope is either a `owner/repo` string that targets a single repository,
/// or an org slug (e.g. `"myorg"`) that targets all runners in an organisation.
/// Scopes are stored in `UserDefaults` and read back on every access so changes
/// survive app restarts without requiring an explicit save call.
/// Access the shared instance via `ScopeStore.shared`.
final class ScopeStore {
    /// Shared singleton — the single source of truth for all scope read/write operations.
    static let shared = ScopeStore()

    /// The `UserDefaults` key under which the scopes array is persisted.
    private let key = "scopes"

    /// The current list of scopes, read from and written directly to `UserDefaults`
    /// on every access. Changes are immediately durable across app launches.
    var scopes: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// `true` when no scopes have been added yet.
    var isEmpty: Bool { scopes.isEmpty }

    /// Appends `scope` to the persisted list after trimming leading/trailing whitespace.
    /// No-ops silently if the trimmed value is empty or already present (dedup guard).
    func add(_ scope: String) {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scopes.contains(trimmed) else { return }
        scopes.append(trimmed)
    }

    /// Removes all entries equal to `scope` from the persisted list.
    func remove(_ scope: String) {
        scopes.removeAll { $0 == scope }
    }
}
