import SwiftUI

// MARK: - RunnerStoreObservable

/// `ObservableObject` bridge that mirrors `RunnerStore` state into SwiftUI `@Published`
/// properties. A single instance is owned by `AppDelegate` and passed into every view
/// that needs live runner / job / action data.
///
/// `reload()` is the ONE place where store state is copied into published properties.
/// It always runs on the main thread and suppresses SwiftUI animations (ref #52 #54).
///
/// `@MainActor` provides compile-time enforcement that all mutations happen on the
/// main thread, preventing accidental background-context calls (fix #6 / #314).
///
/// Note: display caps (e.g. 10 visible actions, 3 inline jobs) are enforced in the
/// view layer via `visibleCount` — not here. This observable mirrors the full store.
@MainActor
final class RunnerStoreObservable: ObservableObject {
    /// All action groups from `RunnerStore.shared` (display limit controlled by view).
    @Published private(set) var actions: [ActionGroup] = []
    /// All active jobs from `RunnerStore.shared` (display limit controlled by view).
    @Published private(set) var jobs: [ActiveJob] = []
    /// All known self-hosted runners.
    @Published private(set) var runners: [Runner] = []
    /// `true` when the most recent poll hit a GitHub rate limit.
    @Published private(set) var isRateLimited: Bool = false

    // MARK: - Reload

    /// Copies current `RunnerStore.shared` state into the published properties.
    /// Uses `withAnimation(nil)` to prevent layout thrashing (RULE 5 — ref #52 #54 #57).
    /// Mutation is safe because the class is `@MainActor`.
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
