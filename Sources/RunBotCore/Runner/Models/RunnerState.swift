// RunnerState.swift
// RunBotCore
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
/// Only `LocalRunnerStore` (in `RunBotCore`) writes them in practice.
/// `availableUpdate` is likewise `public var`: it is written once on launch by
/// `AppDelegate+PanelSetup` (app layer, different module) — `internal(set)` would
/// block that assignment. In practice only the startup Task writes it.
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
    /// the setter to `RunBotCore` and fail to satisfy the requirement at the module interface.
    /// In practice, only `LocalRunnerStore` (inside `RunBotCore`) ever writes this property;
    /// the `public` setter is a type-system necessity, not an invitation for external mutation.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    ///
    /// Pushed by `LocalRunnerStore` alongside `localRunners`.
    /// See `localRunners` for the access-level rationale.
    public var isLocalScanning: Bool = false

    /// The latest available version string if a newer version exists, or `nil` if
    /// up to date.
    ///
    /// **Read-only for all callers.** Write via `setAvailableUpdate(_:)` below.
    ///
    /// **Why `public private(set)` with a dedicated setter method:**
    /// `private(set)` restricts the synthesised setter to `RunnerState` itself — direct
    /// assignment from outside the type (including from the `RunBot` app module) is a
    /// compile error. Cross-module mutation is intentionally funnelled through the
    /// `public func setAvailableUpdate(_:)` method below, which is the single authorised
    /// write site and keeps ad-hoc mutation visible in code review.
    public private(set) var availableUpdate: String?

    /// Sets `availableUpdate`. Called exactly once, from the startup Task in
    /// `AppDelegate+PanelSetup`, after `UpdateChecker.checkForUpdate` resolves.
    ///
    /// Using an explicit method (rather than direct property assignment) makes the
    /// single authorised write site obvious and prevents ad-hoc mutation elsewhere.
    public func setAvailableUpdate(_ version: String?) {
        availableUpdate = version
    }

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    /// Creates an empty `RunnerState`.
    public init() {}
}
