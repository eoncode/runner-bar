import Combine
import Foundation
import SwiftUI

// MARK: - RunnerStoreObservable

/// Observable bridge between the singleton `RunnerStore` and SwiftUI views.
/// `PopoverMainView`, `SettingsView`, and `AppDelegate` hold one shared instance.
/// Call `reload(localRunnerStore:)` to pull the latest state from `RunnerStore.shared`
/// and `LocalRunnerStore` onto the main thread.
///
/// ⚠️ NOT @MainActor: AppDelegate creates this as a stored property (`private let observable`)
/// in a synchronous nonisolated context. @MainActor would make init() and reload() async
/// from outside the actor and break AppDelegate.swift:40 and AppDelegate.swift:281.
/// RunnerStore.onChange always fires on DispatchQueue.main so thread safety is preserved.
final class RunnerStoreObservable: ObservableObject {
    /// Mirrors `RunnerStore.shared.runners` (remote GitHub API runners).
    @Published private(set) var runners: [Runner] = []
    /// Mirrors `RunnerStore.shared.jobs`.
    @Published private(set) var jobs: [ActiveJob] = []
    /// Mirrors `RunnerStore.shared.actions`.
    @Published private(set) var actions: [ActionGroup] = []
    /// Mirrors `RunnerStore.shared.isRateLimited`.
    @Published private(set) var isRateLimited = false
    /// Mirrors `LocalRunnerStore.shared.runners` (local self-hosted runners).
    @Published private(set) var localRunners: [RunnerModel] = []

    /// Creates a new instance; initial state is populated on first `reload(localRunnerStore:)` call.
    init() {}

    /// Pulls the current state from `RunnerStore.shared` and `LocalRunnerStore` with no animation
    /// (see REGRESSION GUARD in PopoverMainView — NEVER add animation here).
    /// ❌ NEVER add objectWillChange.send() here — double-publish causes flicker.
    /// ❌ NEVER remove withAnimation(nil) — removing it re-enables SwiftUI spring animation on every poll.
    /// ❌ NEVER make this async or move it off the main thread.
    /// ❌ NEVER call this from popoverDidClose() — clobbers savedNavState.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    func reload(localRunnerStore: LocalRunnerStore = LocalRunnerStore.shared) {
        let store = RunnerStore.shared
        log("RunnerStoreObservable › reload — actions=\(store.actions.count) jobs=\(store.jobs.count) runners=\(store.runners.count) localRunners=\(localRunnerStore.runners.count)")
        withAnimation(nil) {
            runners = store.runners
            jobs = store.jobs
            actions = store.actions
            isRateLimited = store.isRateLimited
            localRunners = localRunnerStore.runners
        }
    }
}
