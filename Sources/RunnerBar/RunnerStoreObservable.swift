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
/// from outside the actor and break AppDelegate.swift:40 and AppDelegate.swift:281.
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

    init() {}

    /// Pulls the current state from `RunnerStore.shared` with no animation
    /// (see REGRESSION GUARD in PopoverMainView — NEVER add animation here).
    func reload() {
        withAnimation(nil) {
            runners = RunnerStore.shared.runners
            jobs = RunnerStore.shared.jobs
            actions = RunnerStore.shared.actions
            isRateLimited = RunnerStore.shared.isRateLimited
        }
    }
}
