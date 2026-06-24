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
            // DefaultScopePreferencesStore is now a typealias for ScopePreferencesStore.
            // We pass the shared singleton directly — it satisfies
            // `any ScopePreferencesStoreProtocol` because the actor conforms. (#1538)
            preferencesStore: ScopePreferencesStore.shared,
            terminalLauncher: DefaultTerminalLauncher()
        )
        await useCase.fireIfNeeded(group: group, scope: scope, callsite: callsite)
    }

    // periphery:ignore - intentionally retained for future one-shot evaluation entry points.
    /// Evaluates all action groups and fires the failure hook for any that qualify.
    ///
    /// Each group is evaluated independently; groups that do not qualify are silently skipped.
    /// Runs the async `fireIfNeeded` calls inside a fire-and-forget `Task` so this
    /// method can be called synchronously from an `ObservationLoop` onChange closure.
    ///
    /// Scope derivation mirrors `RunnerPoller.scopeFromActionGroup`:
    /// `group.repo` is used when non-empty; otherwise the first run's `htmlUrl` is
    /// parsed via `scopeFromHtmlUrl`. An empty string is passed only as a last resort
    /// (no data available), which will cause `fireIfNeeded` to skip the hook silently.
    ///
    /// ⚠️ **Wiring constraint — do NOT call from `failureHookLoop` or any observer
    /// that fires on every poll cycle.**
    ///
    /// `runnerState.actions` is written unconditionally on every `applyFetchResult`
    /// call, so any `ObservationLoop` that reads it will call `onChange` every cycle.
    /// `evaluate(_:)` has no access to `RunnerPoller.seenGroupIDs` and therefore
    /// cannot distinguish newly-failed groups from already-fired ones — calling it
    /// from such an observer causes the terminal command to open on every poll cycle
    /// for every group that remains in the actions list.
    ///
    /// The canonical, deduplicated hook-firing path is the `fireFailureHook` closure
    /// injected into `RunnerPoller.init` (callsite: `"pollResultBuilder"`), which is
    /// guarded by `seenGroupIDs` inside the `RunnerPoller` actor.
    ///
    /// This method is intentionally kept for future use cases where the caller can
    /// guarantee freshness (e.g. a one-shot evaluate at app launch before the poll
    /// loop starts). It must never be wired to a continuous observation loop.
    static func evaluate(_ actions: [WorkflowActionGroup]) {
        Task {
            for group in actions {
                // group.repo can be empty for org runners; mirror the fallback logic
                // used in RunnerPoller.scopeFromActionGroup rather than passing repo
                // directly, which would silently pass an empty scope to fireIfNeeded.
                let scope: String
                if !group.repo.isEmpty {
                    scope = group.repo
                } else if let firstRun = group.runs.first,
                          let htmlUrl = firstRun.htmlUrl,
                          let derived = scopeFromHtmlUrl(htmlUrl) {
                    scope = derived
                } else {
                    scope = ""
                }
                await fireIfNeeded(group: group, scope: scope, callsite: "observationLoop")
            }
        }
    }
}
