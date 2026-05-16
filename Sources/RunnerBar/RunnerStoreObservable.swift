// swiftlint:disable all
import Foundation
import SwiftUI

/// SwiftUI bridge for `RunnerStore`.
///
/// Subscribes to `RunnerStore.shared.onChange` and republishes runners/jobs/actions
/// as `@Published` properties so SwiftUI views re-render after each poll.
///
/// Injected into the view hierarchy as an `@EnvironmentObject` by `AppDelegate.wrapEnv`.
final class RunnerStoreObservable: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var jobs: [ActiveJob] = []
    @Published var actions: [ActionGroup] = []

    private let store: RunnerStore

    init(store: RunnerStore = RunnerStore.shared) {
        self.store = store
        // Mirror current state immediately (covers the case where a poll already fired).
        self.runners = store.runners
        self.jobs    = store.jobs
        self.actions = store.actions
        // Subscribe to future polls.
        store.onChange = { [weak self] in
            guard let self else { return }
            // onChange is already dispatched to main by RunnerStore.
            self.runners = store.runners
            self.jobs    = store.jobs
            self.actions = store.actions
        }
    }

    /// Triggers an immediate poll.
    func reload() {
        store.fetch()
    }

    /// Persists new GitHub credentials and immediately re-polls.
    /// Called by `AccountSettingsView` when the user taps "Save & Reconnect".
    func applySettings(_ settings: SettingsStore) {
        SettingsStore.shared.githubToken = settings.githubToken
        SettingsStore.shared.githubOrg   = settings.githubOrg
        store.fetch()
    }
}
