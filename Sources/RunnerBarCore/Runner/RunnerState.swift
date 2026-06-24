// RunnerState.swift
// RunnerBarCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
///
/// The five poll-written properties are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Views and app-layer code are read-only consumers.
@Observable
@MainActor
public final class RunnerState {
    /// The current list of GitHub self-hosted runners for all active scopes.
    public internal(set) var runners: [Runner] = []
    /// Active and recently-completed jobs across all active scopes.
    public internal(set) var jobs: [ActiveJob] = []
    /// Workflow action groups (runs) across all active scopes.
    public internal(set) var actions: [WorkflowActionGroup] = []
    /// Whether the GitHub API rate limit has been hit.
    ///
    /// When `true`, polling is paused until `rateLimitResetDate`.
    public internal(set) var isRateLimited = false
    /// The date at which the rate limit resets, if currently rate-limited.
    public internal(set) var rateLimitResetDate: Date?

    // periphery:ignore - scaffolding; applyFetchResult does not write this yet.
    // TODO: wire applyFetchResult to set fetchError on network/decode failures.
    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    ///
    /// Typed `(any Error & Sendable)?` rather than `Error?` so the value can
    /// safely cross actor isolation boundaries when it is eventually read from
    /// a non-`@MainActor` context (e.g. logging or telemetry in `RunnerPoller`).
    /// Changing from `Error?` after write sites are wired would require updating
    /// all those call sites, so the correct type is established here while the
    /// property is still unwired.
    ///
    /// `internal` until `applyFetchResult` is wired to write it; demoted from
    /// `public` to keep the `RunnerBarCore` API surface clean.
    var fetchError: (any Error & Sendable)?

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    /// Creates an empty `RunnerState`.
    public init() {}
}
