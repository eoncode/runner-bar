// ObservationLoop.swift
// RunnerBarCore

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
    ///   - observe:  A closure that reads one or more `@Observable` properties.
    ///               Re-executed after each `onChange` to re-register tracking.
    ///   - onChange: Called whenever any property read in `observe` changes.
    public init(
        observe: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.observe = observe
        self.onChange = onChange
        register()
    }

    deinit {
        isRunning = false
    }

    /// Registers a single `withObservationTracking` pass and schedules re-registration on change.
    private func register() {
        withObservationTracking {
            observe()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.onChange()
                self.register()
            }
        }
    }
}
