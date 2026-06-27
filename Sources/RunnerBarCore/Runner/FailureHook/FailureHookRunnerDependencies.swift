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

    func preferences(for scope: String) -> ScopePreferences
    func setPreferences(_ prefs: ScopePreferences, for scope: String)
    func modifyPreferences(for scope: String, with mutation: @Sendable (inout ScopePreferences) -> Void)

    // MARK: - Alias

    func alias(for scope: String) -> String?
    func setAlias(_ alias: String?, for scope: String)
    func displayName(for scope: String) -> String

    // MARK: - Polling interval

    func pollingInterval(for scope: String) -> Int?
    func setPollingInterval(_ interval: Int?, for scope: String)

    // MARK: - Notification overrides

    func notifyOnSuccess(for scope: String) -> Bool?
    func setNotifyOnSuccess(_ value: Bool?, for scope: String)
    func notifyOnFailure(for scope: String) -> Bool?
    func setNotifyOnFailure(_ value: Bool?, for scope: String)

    // MARK: - Failure hook

    func failureHookEnabled(for scope: String) -> Bool
    func setFailureHookEnabled(_ enabled: Bool, for scope: String)
    func failureHookCommand(for scope: String) -> String?
    func setFailureHookCommand(_ command: String?, for scope: String)
    func localRepoPath(for scope: String) -> String?
    func setLocalRepoPath(_ path: String?, for scope: String)
    func failureHookBranch(for scope: String) -> String?
    func setFailureHookBranch(_ branch: String?, for scope: String)

    // MARK: - Cleanup

    func cleanUp(scope: String)
}

// MARK: - ScopePreferencesStoreProtocol default implementations

public extension ScopePreferencesStoreProtocol {
    func modifyPreferences(for scope: String, with mutation: @Sendable (inout ScopePreferences) -> Void) {
        var prefs = preferences(for: scope)
        mutation(&prefs)
        setPreferences(prefs, for: scope)
    }
}

// MARK: - TerminalLauncherProtocol

/// Abstracts the terminal-launcher dependency so `FailureHookRunnerUseCase` can
/// be tested without spawning real processes.
public protocol TerminalLauncherProtocol: Sendable {
    @MainActor func open(_ command: String)
}
