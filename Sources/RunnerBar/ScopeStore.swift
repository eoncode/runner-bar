import Combine
import Foundation

/// Persists the list of watched GitHub scopes (e.g. `"owner/repo"` or `"myorg"`).
///
/// A scope is either a `owner/repo` string that targets a single repository,
/// or an org slug that targets all runners in an organisation.
/// Scopes are stored in `UserDefaults` and read back on every access so changes
/// survive app restarts without requiring an explicit save call.
///
/// Conforms to ObservableObject so SwiftUI views can use @StateObject / @ObservedObject
/// and automatically re-render when scopes are mutated.
///
/// Set `onMutate` to be notified after add/remove completes.
final class ScopeStore: ObservableObject {
    /// Shared singleton — the single source of truth for all scope read/write operations.
    static let shared = ScopeStore()

    private let key = "scopes"

    /// Optional callback invoked after a successful add or remove.
    var onMutate: (() -> Void)?

    /// The current list of scopes, read from and written to `UserDefaults` on every access.
    /// Calls `objectWillChange.send()` before each mutation so SwiftUI observing views update.
    var scopes: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: key)
        }
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
    /// No-ops (and suppresses the `onMutate` callback) when `scope` is not present.
    func remove(_ scope: String) {
        guard scopes.contains(scope) else { return }
        scopes.removeAll(where: { $0 == scope })
        onMutate?()
    }
}
