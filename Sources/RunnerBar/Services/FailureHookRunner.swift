// FailureHookRunner.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - FailureHookRunner

/// Production shim for `FailureHookRunnerUseCase`.
///
/// Creates the use-case with the concrete production adapters
/// (`DefaultScopePreferencesStore`, `DefaultTerminalLauncher`) and
/// delegates `fireIfNeeded` to it. All business logic lives in
/// `FailureHookRunnerUseCase`; this type exists only to maintain the
/// existing call-site API (`FailureHookRunner.fireIfNeeded(group:scope:callsite:)`).
///
/// - Note: The full token resolution table, shell-quoting contract, and
///   thread-safety notes are documented in `FailureHookRunnerUseCase`.
///
/// Thinned to a production shim as part of #1363 (P7/P8 audit); all business logic
/// now lives in `FailureHookRunnerUseCase`.
enum FailureHookRunner {

    /// Default command used when no command has been explicitly saved for the scope.
    /// Shared with `FailureHookCommandSheet` for pre-population and referenced by
    /// `FailureHookRunnerUseCase` as the fallback command.
    /// Forwards to `FailureHookRunnerUseCase.defaultCommand` — canonical definition lives there.
    static let defaultCommand = FailureHookRunnerUseCase.defaultCommand

    /// Forwards to `FailureHookRunnerUseCase` wired with production dependencies.
    /// `async` because `fireIfNeeded` is now a structured async call — callers
    /// must provide a Task scope (see `RunnerStore+PollBridge`).
    /// `sending` removed: no `Task.detached` boundary crossing, `WorkflowActionGroup`
    /// is `Sendable` so `MainActor.run` hops inside the use-case are safe without it.
    static func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String = "unknown"
    ) async {
        let useCase = FailureHookRunnerUseCase(
            preferencesStore: DefaultScopePreferencesStore(),
            terminalLauncher: DefaultTerminalLauncher()
        )
        await useCase.fireIfNeeded(group: group, scope: scope, callsite: callsite)
    }
}
