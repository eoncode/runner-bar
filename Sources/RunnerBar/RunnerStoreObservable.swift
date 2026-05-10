import Combine
import Foundation
import SwiftUI

// MARK: - RunnerStoreObservable

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  RunnerStoreObservable — REGRESSION CONTRACT — READ BEFORE EDITING  ☠️  ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║                                                                              ║
// ║  This class is the ONLY bridge between RunnerStore and SwiftUI views.        ║
// ║  It is intentionally NOT @MainActor (see reload() docstring for why).        ║
// ║                                                                              ║
// ║  WHAT BROKE IN THE PAST AND MUST NEVER HAPPEN AGAIN:                        ║
// ║                                                                              ║
// ║  1. objectWillChange.send() was added inside reload().                       ║
// ║     Result: double-publish, SwiftUI re-rendered twice per poll cycle,        ║
// ║     causing the popover to flicker and fittingSize to be re-evaluated        ║
// ║     at the wrong time. NEVER add objectWillChange.send() here.               ║
// ║                                                                              ║
// ║  2. reload() was called from popoverDidClose() in AppDelegate.               ║
// ║     Result: clobbered savedNavState, user lost navigation position.          ║
// ║     NEVER call reload() from popoverDidClose().                              ║
// ║                                                                              ║
// ║  3. reload() was made async or dispatched to a background queue.             ║
// ║     Result: race condition — published properties updated off main thread,   ║
// ║     SwiftUI threw runtime warnings and occasionally crashed.                 ║
// ║     NEVER make reload() async. NEVER dispatch it off the main thread.        ║
// ║                                                                              ║
// ║  4. withAnimation(nil) was removed from reload().                            ║
// ║     Result: SwiftUI's default spring animation ran on every poll, causing    ║
// ║     rows to visually bounce every 30 s. NEVER remove withAnimation(nil).     ║
// ║                                                                              ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

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

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║  ☠️  reload() — ABSOLUTE RULES — NEVER VIOLATE THESE  ☠️             ║
    // ╠═══════════════════════════════════════════════════════════════════════╣
    // ║                                                                       ║
    // ║  ❌ NEVER add objectWillChange.send() here — causes double-publish   ║
    // ║     and popover flicker. The @Published properties already fire it.   ║
    // ║                                                                       ║
    // ║  ❌ NEVER remove withAnimation(nil) — removing it re-enables SwiftUI ║
    // ║     default spring animation on every poll, making rows bounce.       ║
    // ║                                                                       ║
    // ║  ❌ NEVER make this function async or move it off the main thread     ║
    // ║     RunnerStore.onChange already guarantees main-thread delivery.     ║
    // ║                                                                       ║
    // ║  ❌ NEVER call this from popoverDidClose() in AppDelegate             ║
    // ║     It clobbers savedNavState and loses nav position on reopen.       ║
    // ║                                                                       ║
    // ║  ✔  ONLY call from:                                                   ║
    // ║      - AppDelegate.openPopover() (once, before popover.show())        ║
    // ║      - RunnerStore.onChange handler (when popoverIsOpen == false)     ║
    // ║      - SettingsView.submitScope() after a user scope mutation          ║
    // ║      - PopoverMainView runnerRefreshTimer (every 5 s, on main thread) ║
    // ║                                                                       ║
    // ╚═══════════════════════════════════════════════════════════════════════╝
    func reload() {
        withAnimation(nil) {
            runners = RunnerStore.shared.runners
            jobs = RunnerStore.shared.jobs
            actions = RunnerStore.shared.actions
            isRateLimited = RunnerStore.shared.isRateLimited
        }
    }
}
