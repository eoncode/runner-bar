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
        self.runners = store.runners
        self.jobs    = store.jobs
        self.actions = store.actions
        store.onChange = { [weak self] in
            guard let self else { return }
            self.runners = store.runners
            self.jobs    = store.jobs
            self.actions = store.actions
        }
    }

    func reload() {
        store.fetch()
    }

    /// Persists new GitHub credentials, syncs org -> ScopeStore, and re-polls.
    ///
    /// ScopeStore.scopes drives ALL polling. The Settings UI exposes a single
    /// org/user field (githubOrg). We translate it here so there is always at
    /// least one scope to poll against.
    /// ❌ NEVER remove the ScopeStore sync — without it actions/runners stay empty.
    func applySettings(_ settings: SettingsStore) {
        SettingsStore.shared.githubToken = settings.githubToken
        SettingsStore.shared.githubOrg   = settings.githubOrg
        let org = settings.githubOrg.trimmingCharacters(in: .whitespaces)
        if !org.isEmpty {
            if ScopeStore.shared.scopes.isEmpty {
                ScopeStore.shared.add(org)
            } else {
                // Replace the first (primary) scope with the new org value.
                // Extra manually-added repo scopes stay intact.
                var updated = ScopeStore.shared.scopes
                updated[0] = org
                for s in ScopeStore.shared.scopes { ScopeStore.shared.remove(s) }
                for s in updated { ScopeStore.shared.add(s) }
            }
        }
        store.fetch()
    }
}
