import Foundation

/// Persists the list of watched GitHub scopes (e.g. `"owner/repo"` or `"myorg"`).
///
/// A scope is either a `owner/repo` string that targets a single repository,
/// or an org slug that targets all runners in an organisation.
/// Scopes are stored in `UserDefaults` and read back on every access so changes
/// survive app restarts without requiring an explicit save call.
///
/// Set `onMutate` to be notified after add/remove completes.
final class ScopeStore {
    /// Shared singleton — the single source of truth for all scope read/write operations.
    static let shared = ScopeStore()

    private let key = "scopes"

    /// Optional callback invoked after a successful add or remove.
    var onMutate: (() -> Void)?

    /// The current list of scopes, read from and written to `UserDefaults` on every access.
    var scopes: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// `true` when no scopes have been added yet.
    var isEmpty: Bool { scopes.isEmpty }

    /// Appends `scope` after trimming whitespace. No-ops if empty or already present.
    func add(_ scope: String) {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scopes.contains(trimmed) else { return }
        scopes.append(trimmed)
        onMutate?()
    }

    /// Removes all entries equal to `scope` from the persisted list.
    func remove(_ scope: String) {
        scopes.removeAll(where: { $0 == scope })
        onMutate?()
    }
}
