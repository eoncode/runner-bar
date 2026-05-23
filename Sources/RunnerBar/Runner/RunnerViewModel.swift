import Combine
import Foundation
import SwiftUI

// MARK: - RunnerViewModel

/// Observable bridge between the singleton `RunnerStore` and SwiftUI views.
/// `PopoverMainView`, `SettingsView`, and `AppDelegate` hold one shared instance.
/// Call `reload(localRunnerStore:)` to pull the latest state from `RunnerStore.shared`
/// and `LocalRunnerStore` onto the main thread.
///
/// ⚠️ @MainActor: ensures all Published mutations happen on the main actor.
/// AppDelegate creates this as a stored property; init() is safe because
/// AppDelegate itself runs on the main thread at launch.
final class RunnerViewModel: ObservableObject {
    /// Mirrors `RunnerStore.shared.runners` (remote GitHub API runners).
    @Published private(set) var runners: [Runner] = []
    /// Mirrors `RunnerStore.shared.jobs`.
    @Published private(set) var jobs: [ActiveJob] = []
    /// Mirrors `RunnerStore.shared.actions`.
    @Published private(set) var actions: [WorkflowActionGroup] = []
    /// Mirrors `RunnerStore.shared.isRateLimited`.
    @Published private(set) var isRateLimited = false
    /// Mirrors `LocalRunnerStore.shared.runners` (local self-hosted runners).
    @Published private(set) var localRunners: [RunnerModel] = []

    /// Creates a new instance; initial state is populated on first `reload(localRunnerStore:)` call.
    init() {
        // No custom initialisation needed; all state is populated via reload(localRunnerStore:).
    }

    /// Pulls the current state from `RunnerStore.shared` and `LocalRunnerStore` with no animation
    /// (see REGRESSION GUARD in PopoverMainView — NEVER add animation here).
    /// ❌ NEVER add objectWillChange.send() here — double-publish causes flicker.
    /// ❌ NEVER remove withAnimation(nil) — removing it re-enables SwiftUI spring animation on every poll.
    /// ❌ NEVER make this async or move it off the main thread.
    /// ❌ NEVER call this from popoverDidClose() — clobbers savedNavState.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    @MainActor func reload(localRunnerStore: LocalRunnerStore? = nil) {
        // Resolving .shared inside the body (not in the parameter default) avoids the
        // Swift 6 warning: "main actor-isolated static property 'shared' can not be
        // referenced from a nonisolated context" that arises with default parameter exprs.
        let localStore = localRunnerStore ?? LocalRunnerStore.shared
        let store = RunnerStore.shared
        log("RunnerViewModel › reload — actions=\(store.actions.count) jobs=\(store.jobs.count) runners=\(store.runners.count) localRunners=\(localStore.runners.count)")
        withAnimation(nil) {
            runners = store.runners
            jobs = store.jobs
            actions = store.actions
            isRateLimited = store.isRateLimited
            localRunners = localStore.runners
        }
    }
}
