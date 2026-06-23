// FailureHookRunnerDependencies.swift
// RunnerBarCore
import Foundation

// MARK: - ScopePreferencesStoreProtocol

/// Full read/write interface for per-scope `UserDefaults` preferences.
///
/// Constrained to `Actor` (which implies `Sendable`) so every call site is
/// visibly `async` — making actor crossings explicit and compiler-enforced (P4).
public protocol ScopePreferencesStoreProtocol: Actor {

    // MARK: - Bulk snapshot / write

    /// Returns a full `ScopePreferences` snapshot for the scope in one actor hop.
    ///
    /// Prefer this over calling individual getters in sequence when multiple fields
    /// are needed at once (e.g. before presenting `ScopeEditSheet`) — one `await`
    /// instead of N. The returned value is a value-type copy and is safe to use
    /// outside the actor.
    func preferences(for scope: String) -> ScopePreferences

    /// Writes a complete `ScopePreferences` snapshot for the scope in one actor hop.
    ///
    /// Prefer this over calling multiple individual setters in sequence (e.g. in
    /// `confirmSave()`) — one `await` and one encode/write instead of N.
    func setPreferences(_ prefs: ScopePreferences, for scope: String)

    /// Reads, mutates, and writes the `ScopePreferences` for `scope` atomically
    /// within a single actor hop.
    ///
    /// Use this instead of a separate `preferences(for:)` + `setPreferences(_:for:)`
    /// pair when you need to mutate a subset of fields while preserving the rest.
    /// The two-hop alternative violates P10: another writer can change the blob
    /// between the read hop and the write hop, causing the second hop to silently
    /// overwrite intermediate changes with a stale snapshot.
    ///
    /// A default implementation is provided via a protocol extension; concrete
    /// conformers do not need to implement this unless they have a specialised
    /// storage model.
    ///
    /// - Parameters:
    ///   - scope: The scope identifier whose preferences should be modified.
    ///   - mutation: A closure that receives the current `ScopePreferences` as
    ///     an `inout` value and applies all desired changes before returning.
    ///     The closure runs synchronously inside the actor.
    func modifyPreferences(for scope: String, with mutation: (inout ScopePreferences) -> Void)

    // MARK: - Alias

    /// Human-readable alias for the scope. `nil` = display raw scope string.
    func alias(for scope: String) -> String?
    /// Sets (or clears) the human-readable alias for the scope.
    func setAlias(_ alias: String?, for scope: String)
    /// Display name: alias if set, otherwise the raw scope string.
    func displayName(for scope: String) -> String

    // MARK: - Polling interval

    /// Per-scope polling interval override in seconds. `nil` = use global setting.
    func pollingInterval(for scope: String) -> Int?
    /// Sets (or clears) the per-scope polling interval override.
    func setPollingInterval(_ interval: Int?, for scope: String)

    // MARK: - Notification overrides

    /// Per-scope notify-on-success override. `nil` = use global.
    func notifyOnSuccess(for scope: String) -> Bool?
    /// Sets (or clears) the per-scope notify-on-success override.
    func setNotifyOnSuccess(_ value: Bool?, for scope: String)
    /// Per-scope notify-on-failure override. `nil` = use global.
    func notifyOnFailure(for scope: String) -> Bool?
    /// Sets (or clears) the per-scope notify-on-failure override.
    func setNotifyOnFailure(_ value: Bool?, for scope: String)

    // MARK: - Failure hook

    /// Returns `true` if the failure hook is enabled for the given scope.
    func failureHookEnabled(for scope: String) -> Bool
    /// Persists whether the failure hook is enabled for the scope.
    func setFailureHookEnabled(_ enabled: Bool, for scope: String)
    /// Returns the custom failure-hook command for the scope, or `nil` if none is set.
    func failureHookCommand(for scope: String) -> String?
    /// Sets (or clears) the failure-hook shell command for the scope.
    func setFailureHookCommand(_ command: String?, for scope: String)
    /// Returns the local repository path for the scope, or `nil` if not set.
    func localRepoPath(for scope: String) -> String?
    /// Sets (or clears) the local repository path for the scope.
    func setLocalRepoPath(_ path: String?, for scope: String)
    /// Returns the branch filter for the failure hook, or `nil` if all branches should trigger.
    func failureHookBranch(for scope: String) -> String?
    /// Sets (or clears) the branch filter for the failure hook.
    func setFailureHookBranch(_ branch: String?, for scope: String)

    // MARK: - Cleanup

    /// Removes all persisted preferences for the scope.
    /// Call from `ScopeStore.remove(id:)` to avoid orphaned data accumulating.
    func cleanUp(scope: String)
}

// MARK: - ScopePreferencesStoreProtocol default implementations

/// Default implementations for `ScopePreferencesStoreProtocol` convenience methods.
public extension ScopePreferencesStoreProtocol {
    /// Default implementation: reads, applies `mutation`, and writes — all inside
    /// the actor so the full RMW is a single hop. Concrete conformers can override
    /// this if they have a specialised storage model, but the default is correct
    /// for any conformer that implements `preferences(for:)` and `setPreferences(_:for:)`.
    func modifyPreferences(for scope: String, with mutation: (inout ScopePreferences) -> Void) {
        var prefs = preferences(for: scope)
        mutation(&prefs)
        setPreferences(prefs, for: scope)
    }
}

// MARK: - TerminalLauncherProtocol

/// Abstracts the terminal-launcher dependency so `FailureHookRunnerUseCase` can
/// be tested without spawning real processes.
///
/// `open(_:)` is `@MainActor` because `NSAppleScript` (used by the production
/// implementation) must run on the main thread. Call sites must dispatch via
/// `await MainActor.run { terminalLauncher.open(resolved) }` or be `@MainActor`
/// themselves.
public protocol TerminalLauncherProtocol: Sendable {
    /// Opens a terminal application and runs `command`. Must be called on `@MainActor`.
    @MainActor func open(_ command: String)
}
