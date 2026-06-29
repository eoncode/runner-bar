// ObservationLoop.swift
// RunBotCore

import Foundation
import Observation

/// A re-registering `withObservationTracking` wrapper that fires `onChange`
/// every time any `@Observable` property accessed inside `observe` changes.
///
/// **Usage**
/// ```swift
/// let loop = ObservationLoop {
///     _ = myState.someProperty
/// } onChange: {
///     doSomething()
/// }
/// ```
///
/// **Lifecycle**
/// The loop runs for as long as this object is retained. Deinitialising it
/// stops re-registration — no explicit cancel call needed.
///
/// **Threading**
/// Both `observe` and `onChange` are called on the `@MainActor`.
///
/// **`withObservationTracking` onChange thread contract**
/// The `onChange` callback of `withObservationTracking` fires on whichever
/// thread mutated the tracked `@Observable` property — not necessarily the
/// main actor. To guarantee `@MainActor` execution without asserting it,
/// this implementation schedules work via `Task { @MainActor in ... }` rather
/// than `MainActor.assumeIsolated`. This means `onChange` and the subsequent
/// `register()` call are always enqueued onto the main actor executor safely,
/// even if an `@Observable` property is ever written from a background actor.
@MainActor
public final class ObservationLoop {
    /// Closure that reads `@Observable` properties to register tracking.
    private let observe: @MainActor () -> Void
    /// Closure invoked whenever a tracked property changes.
    private let onChange: @MainActor () -> Void
    /// Guards against re-registration after deinit.
    private var isRunning = true

    /// Creates and immediately starts the observation loop.
    ///
    /// - Parameters:
    ///   - observe: A closure that reads one or more `@Observable` properties.
    ///     Re-executed after each `onChange` to re-register tracking.
    ///   - onChange: Called whenever any property read in `observe` changes.
    ///     **Do not mutate `@Observable` properties that `observe` also reads.**
    ///     `onChange` fires before the next `register()` pass, so any mutation
    ///     made here occurs before `withObservationTracking` has re-armed —
    ///     that mutation will not trigger a subsequent `onChange` call in the
    ///     same cycle. Use `onChange` as a side-effect sink (e.g. update an icon,
    ///     trigger a fetch); keep tracked-property mutations in response to the
    ///     property changes themselves, not inside this callback.
    public init(
        observe: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.observe = observe
        self.onChange = onChange
        register()
    }

    /// `isolated deinit` ensures `isRunning = false` executes on the `@MainActor`
    /// executor — the same isolation domain as the `self.isRunning` read in
    /// `register()`'s `Task { @MainActor in guard let self, self.isRunning }` closure.
    /// A plain `deinit` on a `@MainActor` class runs on the releasing thread
    /// (not the main actor) in Swift 6, creating a data race between the write
    /// here and the actor-isolated read in `register()`. `isolated deinit` closes
    /// that race as a language guarantee, matching the pattern used in `RunnerPoller`.
    isolated deinit {
        isRunning = false
    }

    /// Registers a single `withObservationTracking` pass and schedules re-registration on change.
    ///
    /// The `withObservationTracking` onChange callback fires on whichever thread mutated the
    /// property — not necessarily the main actor. We use `Task { @MainActor in ... }` here
    /// rather than `MainActor.assumeIsolated` so that both the `onChange` call and the
    /// subsequent `register()` are always enqueued onto the main executor, even if a
    /// background actor writes the observed property directly.
    ///
    /// Ordering note: `onChange()` intentionally runs before `register()`. This matches
    /// the current callers, which treat `onChange` as a side-effect sink rather than a
    /// source of additional tracked mutations. If a future `onChange` mutates properties
    /// also read by `observe`, those mutations occur before the next tracking pass is
    /// registered and therefore are not themselves observed by that same cycle.
    private func register() {
        withObservationTracking {
            observe()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.onChange()
                self.register()
            }
        }
    }
}
