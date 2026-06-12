// RunnerViewModel.swift
// RunnerBar
import Foundation
import Observation

// MARK: - RunnerViewModel

/// Bridges `RunnerStore` and `LocalRunnerStore` into observable properties consumed by SwiftUI views.
///
/// State is **pushed** into this view model by the stores via `await MainActor.run { }`.
/// No pull / Combine sinks required. The entire class is `@MainActor` because all
/// property mutations and reads must happen on the main thread for SwiftUI rendering.
@MainActor
@Observable
final class RunnerViewModel {
    // periphery:ignore
    /// ❌ Do not use. The single live instance is owned by `AppDelegate` as `observable`.
    ///
    /// `RunnerStore` and `LocalRunnerStore` push state into `AppDelegate.observable` only;
    /// this accessor is never updated and will silently return stale/empty data.
    /// Inject `RunnerViewModel` explicitly via the environment or constructor instead.
    @MainActor static var shared: RunnerViewModel {
        fatalError(
            "RunnerViewModel.shared must not be used. "
            + "The live instance is AppDelegate.observable — inject it via the environment "
            + "or pass it as a constructor argument."
        )
    }

    // MARK: - Observable state (pushed by RunnerStore)
    /// GitHub API-backed runners for the authenticated user's repos and orgs.
    var runners: [Runner] = []
    /// Active jobs across all monitored workflow runs.
    var jobs: [ActiveJob] = []
    /// Grouped workflow actions surfaced in the panel popover.
    var actions: [WorkflowActionGroup] = []
    /// Whether the GitHub API is currently rate-limited.
    var isRateLimited: Bool = false
    /// When the current rate-limit window resets, if known.
    var rateLimitResetDate: Date?

    // MARK: - Observable state (pushed by LocalRunnerStore)
    /// Locally-installed runner agents discovered on this Mac.
    var localRunners: [RunnerModel] = []
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    var isLocalScanning: Bool = false
}
