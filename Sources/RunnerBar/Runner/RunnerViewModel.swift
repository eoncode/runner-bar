// RunnerViewModel.swift
// RunnerBar
import Combine
import Foundation

// MARK: - RunnerViewModel

/// Bridges `RunnerStore` and `LocalRunnerStore` into `@Published` properties consumed by SwiftUI views.
///
/// `reload()` is triggered by Combine sinks in `AppDelegate+PanelSetup` — one on
/// `RunnerStore.didUpdate` and one on `LocalRunnerStore.$runners` — so the view model
/// stays in sync whenever either store publishes new data.
/// The entire class is `@MainActor` because all `@Published` mutations and reads must happen
/// on the main thread to satisfy SwiftUI's rendering requirements.
@MainActor
final class RunnerViewModel: ObservableObject {
    // MARK: - Shared singleton
    /// The app-wide singleton. Always accessed on the main actor.
    static let shared = RunnerViewModel()

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
    /// `nil` in production — `reload()` falls back to `LocalRunnerStore.shared` when this is `nil`.
    /// Tests **must** set this to avoid leaking into the shared production store.
    /// - Note: Because the class is `@MainActor`, this property must be set from a `@MainActor`
    ///   context in tests (e.g. `@MainActor func testFoo()` or `await MainActor.run { ... }`).
    /// - Note: `RunnerStore` has no equivalent DI seam — `reload()` always reads `RunnerStore.shared`
    ///   directly. Tests that need to stub GitHub API state must use the real singleton or a
    ///   separate integration-test approach.
    var localRunnerStore: LocalRunnerStore?

    // MARK: - Reload

    /// Copies the latest state from `RunnerStore` and `LocalRunnerStore` into the published properties.
    ///
    /// Called by Combine sinks in `AppDelegate+PanelSetup` — one on `RunnerStore.didUpdate`
    /// and one on `LocalRunnerStore.$runners`. Also called eagerly in `AppDelegate.openPanel()`
    /// to seed state on first panel open, since the Combine sinks only fire on store changes,
    /// not on initial subscription. Also calls `LocalRunnerStore.refresh()` to trigger a
    /// re-scan of locally-installed runner agents.
    /// - Note: The `LocalRunnerStore.$runners` sink triggers this method, which then calls
    ///   `refresh()`, which eventually publishes to `$runners` again. This is safe because
    ///   `LocalRunnerStore.isScanning` prevents concurrent refresh cycles from stacking.
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
        // Snapshot is taken before refresh() so the UI always shows the last completed scan,
        // not a partial one mid-flight.
        localStore.refresh()
    }
}
