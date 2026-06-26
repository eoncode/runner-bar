// ObservationRelay.swift
// RunnerBar
//
// F-35: Generic replacement for PreferencesObserver and ScopesObserver.

import Observation

// MARK: - ObservationRelay

/// A generic, `@MainActor`-isolated relay that drives a recursive
/// `withObservationTracking` loop for a single observed value.
///
/// Each call to `start()` registers one tracking pass. When the observed
/// value changes, the relay yields the new value into `continuation` and
/// immediately re-registers, keeping the stream alive indefinitely.
///
/// **Isolation:** every method is `@MainActor`, so the local `func observe()`
/// inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation is
/// required and no value crosses an isolation boundary.
///
/// **Visibility:** `internal` — cross-file within `RunnerBarCore` only.
/// `@testable import RunnerBarCore` exposes it to the test target.
///
/// - Note: `Element` is constrained to `Sendable` because values are yielded
///   from inside a `Task { @MainActor }` onChange closure, which crosses an
///   actor boundary. Both `TimeInterval` and `[String]` satisfy this.
@MainActor
final class ObservationRelay<Element: Sendable> {
    /// Pushes new values into the consumer's `AsyncStream`.
    private let continuation: AsyncStream<Element>.Continuation
    /// Returns the current observed value on the `@MainActor`.
    ///
    /// Captured as a closure so the relay stays generic over both
    /// the store protocol and any transformation (e.g. `TimeInterval(…)` cast).
    private let read: @MainActor () -> Element
    /// Guards against registering more than one `withObservationTracking` pass.
    ///
    /// `start()` is idempotent after the first call: subsequent calls return
    /// immediately without registering a second parallel loop. The recursive
    /// re-registration inside `onChange` bypasses this guard because it calls
    /// `start()` only after the previous pass has fired and is no longer active.
    private var isStarted = false

    /// Creates a new relay.
    ///
    /// - Parameters:
    ///   - continuation: The `AsyncStream<Element>.Continuation` to yield into.
    ///   - read: A `@MainActor` closure that reads (and optionally transforms)
    ///     the observed value from its source. Called once per change event,
    ///     and once per registration pass (apply closure) to register the
    ///     tracking dependency — the return value is discarded in the apply
    ///     closure. Callers must ensure `read` is side-effect-free, or accept
    ///     that any side effects fire on every re-registration as well as on
    ///     every change event.
    init(
        continuation: AsyncStream<Element>.Continuation,
        read: @escaping @MainActor () -> Element
    ) {
        self.continuation = continuation
        self.read = read
    }

    /// Registers a single `withObservationTracking` pass and re-registers on change.
    ///
    /// The inner `observe()` function is a local helper that allows
    /// `withObservationTracking` to be called without capturing `self` in the
    /// apply closure, while still being able to reference it in `onChange`.
    ///
    /// Idempotent: calling `start()` more than once on the same relay is a no-op
    /// after the first call. The recursive re-registration in `onChange` resets
    /// `isStarted` before calling `start()` so the guard does not block it.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        func observe() {
            // Capture continuation by value (strong) so it is reachable even
            // after self is deallocated — required for the finish() call below.
            let continuation = self.continuation
            withObservationTracking {
                // read() is called here solely to register the tracking dependency
                // with the Observation framework. Its return value is intentionally
                // discarded. The read closure must be pure (or callers must accept
                // that side effects fire on every re-registration pass).
                _ = read()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        // The relay has been deallocated. Finish the stream so the
                        // for-await consumer exits cleanly and releases the continuation,
                        // breaking the relay ↔ continuation reference cycle. Without
                        // this the stream stays open and onChange Tasks keep scheduling
                        // after the owning context is gone.
                        continuation.finish()
                        return
                    }
                    // read() is called here rather than captured at onChange time.
                    // If the observed value changes again before this Task executes,
                    // rapid back-to-back changes coalesce — the consumer sees only
                    // the latest value. This is inherited behaviour (present in the
                    // original PreferencesObserver/ScopesObserver) and intentional:
                    // current use-sites are restart-only consumers, so skipping
                    // intermediate values is harmless.
                    self.isStarted = false
                    self.continuation.yield(self.read())
                    self.start()
                }
            }
        }
        observe()
    }
}
