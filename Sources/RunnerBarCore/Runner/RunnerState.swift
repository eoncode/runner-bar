// RunnerState.swift
// RunnerBarCore

import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
@Observable
@MainActor
public final class RunnerState {
    /// The current list of GitHub self-hosted runners for all active scopes.
    public var runners: [Runner] = []
    /// Active and recently-completed jobs across all active scopes.
    public var jobs: [ActiveJob] = []
    /// Workflow action groups (runs) across all active scopes.
    public var actions: [WorkflowActionGroup] = []
    /// Whether the GitHub API rate limit has been hit.
    ///
    /// When `true`, polling is paused until `rateLimitResetDate`.
    public var isRateLimited = false
    /// The date at which the rate limit resets, if currently rate-limited.
    public var rateLimitResetDate: Date?

    // periphery:ignore - scaffolding; applyFetchResult does not write this yet.
    // TODO: wire applyFetchResult to set fetchError on network/decode failures.
    // When this becomes live, prefer `(any Error & Sendable)?` so the type remains
    // explicit about Swift 6 cross-actor safety if the value ever needs to cross
    // isolation boundaries.
    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    /// `internal` until `applyFetchResult` is wired to write it; demoted from
    /// `public` to keep the `RunnerBarCore` API surface clean.
    var fetchError: Error?

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    /// Creates an empty `RunnerState`.
    public init() {}
}
