// swiftlint:disable missing_docs unused_closure_parameter
import Foundation
import SwiftUI

// MARK: - RunnerStoreState

/// Snapshot of RunnerStore state exposed to SwiftUI views.
struct RunnerStoreState {
    var runners: [Runner] = []
    var jobs: [ActiveJob] = []
    var actions: [ActionGroup] = []
    /// Alias used by SettingsView's RunnerSettingsView for local runners.
    var localRunners: [Runner] { runners }
}

// MARK: - RunnerStoreObservable

final class RunnerStoreObservable: ObservableObject {
    @Published var state: RunnerStoreState = RunnerStoreState()

    init() {
        reload()
    }

    /// Snapshots the current RunnerStore.shared state into `state`.
    func reload() {
        let store = RunnerStore.shared
        state = RunnerStoreState(
            runners: store.runners,
            jobs: store.jobs,
            actions: store.actions
        )
    }

    /// Applies updated settings and triggers a fresh poll.
    func applySettings(_ settings: SettingsStore) {
        RunnerStore.shared.start()
    }

    func reRunWorkflow(group: ActionGroup) async throws {
        let scope = group.repo
        let runIDs = group.runs.map { $0.id }
        let succeeded = await Task.detached(priority: .userInitiated) {
            runIDs.allSatisfy { reRunFailedJobs(runID: $0, repoSlug: scope) }
        }.value
        if !succeeded { throw RunnerStoreObservableError.actionFailed }
    }

    func cancelWorkflow(group: ActionGroup) async throws {
        let scope = group.repo
        let runIDs = group.runs.map { $0.id }
        let succeeded = await Task.detached(priority: .userInitiated) {
            runIDs.allSatisfy { cancelRun(runID: $0, scope: scope) }
        }.value
        if !succeeded { throw RunnerStoreObservableError.actionFailed }
    }
}

enum RunnerStoreObservableError: Error {
    case actionFailed
}
// swiftlint:enable missing_docs unused_closure_parameter
