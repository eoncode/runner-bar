// swiftlint:disable missing_docs unused_closure_parameter
import Foundation
import SwiftUI

// MARK: - RunnerStoreObservable
final class RunnerStoreObservable: ObservableObject {
    @Published var state: RunnerStoreState
    private var store: RunnerStore

    init(store: RunnerStore = RunnerStore()) {
        self.store = store
        self.state = store.state
        self.store.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                self?.state = newState
            }
        }
    }

    func applySettings(_ settings: SettingsStore) {
        store.applySettings(settings)
    }

    func reRunWorkflow(group: ActionGroup) async throws {
        try await store.reRunWorkflow(group: group)
    }

    func cancelWorkflow(group: ActionGroup) async throws {
        try await store.cancelWorkflow(group: group)
    }
}
// swiftlint:enable missing_docs unused_closure_parameter
