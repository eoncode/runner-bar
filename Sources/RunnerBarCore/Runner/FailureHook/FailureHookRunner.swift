// FailureHookRunner.swift
// RunnerBarCore
import Foundation

// MARK: - FailureHookRunner

/// Production shim for `FailureHookRunnerUseCase`.
///
/// Creates the use-case with the concrete production adapters
/// (`ScopePreferencesStore.shared`, `DefaultTerminalLauncher`) and
/// delegates `fireIfNeeded` to it. All business logic lives in
/// `FailureHookRunnerUseCase`; this type exists only to maintain the
/// existing call-site API (`FailureHookRunner.fireIfNeeded(group:scope:callsite:)`).
///
/// - Note: The full token resolution table, shell-quoting contract, and
///   thread-safety notes are documented in `FailureHookRunnerUseCase`.
///
/// Thinned to a production shim as part of #1363 (P7/P8 audit); all business logic
/// now lives in `FailureHookRunnerUseCase`.
///
/// Moved from `RunnerBar` to `RunnerBarCore` in #1623.
public enum FailureHookRunner {

    /// Default command used when no command has been explicitly saved for the scope.
    /// Forwards to `FailureHookRunnerUseCase.defaultCommand` — canonical definition lives there.
    public static let defaultCommand = FailureHookRunnerUseCase.defaultCommand

    /// Fires the failure hook for `group` if it qualifies, using production dependencies.
    ///
    /// The deduplicated call site is the `fireFailureHook` closure injected into
    /// `RunnerPoller.init` (wired in `AppDelegate+PanelSetup`), which calls this method
    /// with `callsite: "pollResultBuilder"`. Deduplication is enforced by `seenGroupIDs`,
    /// a stored property on `RunnerPoller`; `PollResultBuilder.buildGroupState` receives
    /// it as a parameter, performs the guard check, and returns the updated set that
    /// `RunnerPoller` writes back. The hook therefore fires exactly once per newly-failed group.
    ///
    /// `async` because `fireIfNeeded` is a structured async call — callers must
    /// provide a Task scope.
    public static func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String = "unknown"
    ) async {
        let useCase = FailureHookRunnerUseCase(
            // DefaultScopePreferencesStore is now a typealias for ScopePreferencesStore.
            // We pass the shared singleton directly — it satisfies
            // `any ScopePreferencesStoreProtocol` because the actor conforms. (#1538)
            preferencesStore: ScopePreferencesStore.shared,
            terminalLauncher: DefaultTerminalLauncher()
        )
        await useCase.fireIfNeeded(group: group, scope: scope, callsite: callsite)
    }
}
