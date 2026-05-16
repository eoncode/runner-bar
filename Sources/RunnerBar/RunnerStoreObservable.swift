import Combine
import Foundation
import SwiftUI

// MARK: - RunnerStoreObservable

/// Observable bridge between the singleton `RunnerStore` and SwiftUI views.
/// `PopoverMainView`, `SettingsView`, and `AppDelegate` hold one shared instance.
/// Call `reload()` to pull the latest state from `RunnerStore.shared` onto the main thread.
///
/// ⚠️ NOT @MainActor: AppDelegate creates this as a stored property (`private let observable`)
/// in a synchronous nonisolated context. @MainActor would make init() and reload() async
/// from outside the actor and break AppDelegate.swift.
/// RunnerStore.onChange always fires on DispatchQueue.main so thread safety is preserved.
final class RunnerStoreObservable: ObservableObject {
    /// Mirrors `RunnerStore.shared.runners`.
    @Published private(set) var runners: [Runner] = []
    /// Mirrors `RunnerStore.shared.jobs`.
    @Published private(set) var jobs: [ActiveJob] = []
    /// Mirrors `RunnerStore.shared.actions`.
    @Published private(set) var actions: [ActionGroup] = []
    /// Mirrors `RunnerStore.shared.isRateLimited`.
    @Published private(set) var isRateLimited = false

    /// Creates a new observable bridge with empty initial state.
    init() {}

    /// Pulls the current state from `RunnerStore.shared` with no animation.
    ///
    /// ❌ NEVER add objectWillChange.send() here — double-publish causes flicker.
    /// ❌ NEVER remove withAnimation(nil) — removing it re-enables SwiftUI spring animation on every poll.
    /// ❌ NEVER make this async or move it off the main thread.
    /// ❌ NEVER call this from popoverDidClose() — clobbers savedNavState.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE.
    func reload() {
        let store = RunnerStore.shared
        withAnimation(nil) {
            runners = store.runners
            jobs = store.jobs
            actions = store.actions
            isRateLimited = store.isRateLimited
        }
    }
}
