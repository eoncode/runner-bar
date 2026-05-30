// RunnerViewModel.swift
// RunnerBar
import Combine
import Foundation

// MARK: - RunnerViewModel
//
// Bridges RunnerStore + LocalRunnerStore into @Published properties consumed by SwiftUI views.
// reload() is called on every displayTick (≈1 Hz) from the panel view.

/// Bridges `RunnerStore` and `LocalRunnerStore` into `@Published` properties consumed by SwiftUI views.
/// `reload()` is called on every display tick (≈1 Hz) from the panel view.
final class RunnerViewModel: ObservableObject {
    // MARK: - Shared singleton
    /// The app-wide singleton. Always accessed on the main actor.
    @MainActor static let shared = RunnerViewModel()

    // MARK: - Published state
    /// GitHub API-backed runners for the authenticated user's repos and orgs.
    @Published var runners: [Runner] = []
    /// Active jobs across all monitored workflow runs.
    @Published var jobs: [ActiveJob] = []
    /// Grouped workflow actions surfaced in the panel popover.
    @Published var actions: [WorkflowActionGroup] = []
    /// Locally-installed runner agents discovered on this Mac.
    @Published var localRunners: [RunnerModel] = []
    /// Whether the GitHub API is currently rate-limited.
    @Published var isRateLimited: Bool = false
    /// When the current rate-limit window resets, if known.
    @Published var rateLimitResetDate: Date?

    // MARK: - Dependency injection (for tests)
    /// Override to inject a test double instead of `LocalRunnerStore.shared`.
    var localRunnerStore: LocalRunnerStore?

    // MARK: - Reload

    /// Copies the latest state from `RunnerStore` and `LocalRunnerStore` into published view model properties.
    @MainActor
    func reload() {
        let localStore = localRunnerStore ?? LocalRunnerStore.shared
        let store = RunnerStore.shared
        log("RunnerViewModel › reload — actions=\(store.actions.count) jobs=\(store.jobs.count) runners=\(store.runners.count) localRunners=\(localStore.runners.count)")
        runners = store.runners
        jobs = store.jobs
        actions = store.actions
        localRunners = localStore.runners
        isRateLimited = store.isRateLimited
        rateLimitResetDate = store.rateLimitResetDate
        localStore.refresh()
    }
}
