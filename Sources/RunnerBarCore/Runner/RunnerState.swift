// RunnerState.swift
// RunnerBarCore

import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
@Observable @MainActor
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

    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    public var fetchError: Error?

    /// Creates an empty `RunnerState`.
    public init() {}
}
