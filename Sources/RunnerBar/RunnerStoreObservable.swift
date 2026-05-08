import SwiftUI

// MARK: - RunnerStoreObservable

/// `ObservableObject` bridge that mirrors `RunnerStore` state into SwiftUI `@Published`
/// properties. A single instance is owned by `AppDelegate` and passed into every view
/// that needs live runner / job / action data.
///
/// `reload()` is the ONE place where store state is copied into published properties.
/// It always runs on the main thread and suppresses SwiftUI animations (ref #52 #54).
final class RunnerStoreObservable: ObservableObject {
    /// Action groups to display (live + recently completed, capped at 10).
    @Published private(set) var actions: [ActionGroup] = []
    /// Jobs to display (live + recently completed, capped at 3).
    @Published private(set) var jobs: [ActiveJob] = []
    /// All known self-hosted runners.
    @Published private(set) var runners: [Runner] = []
    /// `true` when the most recent poll hit a GitHub rate limit.
    @Published private(set) var isRateLimited: Bool = false

    // MARK: - Reload

    /// Copies current `RunnerStore.shared` state into the published properties.
    /// Must be called on the main thread. Uses `withAnimation(nil)` to prevent
    /// layout thrashing (RULE 5 — ref #52 #54 #57).
    func reload() {
        let store = RunnerStore.shared
        withAnimation(nil) {
            actions = store.actions
            jobs = store.jobs
            runners = store.runners
            isRateLimited = store.isRateLimited
        }
    }
}
