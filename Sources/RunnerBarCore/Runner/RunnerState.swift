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
/// The six poll-written properties (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`, `fetchError`) are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Two additional properties (`localRunners`, `isLocalScanning`) are `public var`
/// because Swift requires the setter to match the accessibility of a `public` protocol
/// `{ get set }` requirement — see `RunnerViewModelProtocol` for the rationale.
/// Only `LocalRunnerStore` (in `RunnerBarCore`) writes them in practice.
/// Views and app-layer code are read-only consumers of all properties.
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
    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    ///
    /// Set by `RunnerPoller.applyError(_:)`; cleared on every successful
    /// `applyFetchResult`. Views read this to show a non-modal error banner.
    ///
    /// Typed `(any Error)?` — the stored value is always a `RunnerPoller.FetchError`,
    /// which is `Sendable`. The property stays `any Error` for display flexibility;
    /// `@MainActor` isolation on `RunnerState` ensures safe cross-actor reads.
    public internal(set) var fetchError: (any Error)?

    // MARK: - Local runner state (pushed by LocalRunnerStore)

    /// Locally-installed runner agents discovered on this Mac.
    ///
    /// Pushed by `LocalRunnerStore` via `await MainActor.run { }` after every refresh cycle.
    ///
    /// Declared `public var` (not `public internal(set) var`) because Swift requires the
    /// setter to be at least as accessible as the protocol requirement when conforming to a
    /// public protocol with a `{ get set }` requirement. `public internal(set)` would restrict
    /// the setter to `RunnerBarCore` and fail to satisfy the requirement at the module interface.
    /// In practice, only `LocalRunnerStore` (inside `RunnerBarCore`) ever writes this property;
    /// the `public` setter is a type-system necessity, not an invitation for external mutation.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    ///
    /// Pushed by `LocalRunnerStore` alongside `localRunners`.
    /// See `localRunners` for the access-level rationale.
    public var isLocalScanning: Bool = false

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    /// Creates an empty `RunnerState`.
    public init() {}
}
