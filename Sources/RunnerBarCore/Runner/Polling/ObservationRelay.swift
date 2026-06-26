// ObservationRelay.swift
// RunnerBar
//
// F-35: Generic replacement for PreferencesObserver and ScopesObserver.

import Foundation

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

    /// Creates a new relay.
    ///
    /// - Parameters:
    ///   - continuation: The `AsyncStream<Element>.Continuation` to yield into.
    ///   - read: A `@MainActor` closure that reads (and optionally transforms)
    ///     the observed value from its source. Called once per change event.
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
    func start() {
        func observe() {
            withObservationTracking {
                _ = read()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // read() is called here rather than captured at onChange time.
                    // If the observed value changes again before this Task executes,
                    // rapid back-to-back changes coalesce — the consumer sees only
                    // the latest value. This is inherited behaviour (present in the
                    // original PreferencesObserver/ScopesObserver) and intentional:
                    // current use-sites are restart-only consumers, so skipping
                    // intermediate values is harmless.
                    self.continuation.yield(self.read())
                    self.start()
                }
            }
        }
        observe()
    }
}
