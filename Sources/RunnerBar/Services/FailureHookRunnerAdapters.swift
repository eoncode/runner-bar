// FailureHookRunnerAdapters.swift
// RunnerBar
//
// Lightweight production adapters that bridge the static-only
// `ScopePreferencesStore` and `TerminalLauncher` singletons to the
// instance-based protocols expected by `FailureHookRunnerUseCase`.
import Foundation
import RunnerBarCore

// MARK: - DefaultScopePreferencesStore

/// Forwards all calls to the static `ScopePreferencesStore` methods.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
struct DefaultScopePreferencesStore: FailureHookScopePreferencesProtocol {
    /// Forwards to `ScopePreferencesStore.failureHookEnabled(for:)`.
    func failureHookEnabled(for scope: String) -> Bool {
        ScopePreferencesStore.failureHookEnabled(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.failureHookCommand(for:)`.
    func failureHookCommand(for scope: String) -> String? {
        ScopePreferencesStore.failureHookCommand(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.failureHookBranch(for:)`.
    func failureHookBranch(for scope: String) -> String? {
        ScopePreferencesStore.failureHookBranch(for: scope)
    }
    /// Forwards to `ScopePreferencesStore.localRepoPath(for:)`.
    func localRepoPath(for scope: String) -> String? {
        ScopePreferencesStore.localRepoPath(for: scope)
    }
}

// MARK: - DefaultTerminalLauncher

/// Forwards `open(command:)` to `TerminalLauncher.open(command:)`.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
struct DefaultTerminalLauncher: TerminalLauncherProtocol {
    /// Forwards to `TerminalLauncher.open(command:)`. Must be called on `@MainActor`.
    @MainActor
    func open(command: String) {
        TerminalLauncher.open(command: command)
    }
}
