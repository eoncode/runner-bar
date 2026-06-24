// RunnerPollerObservers.swift
// RunnerBarCore
//
// Step 10: Moved from RunnerBar app target to RunnerBarCore.
import Foundation

// MARK: - PreferencesObserver

/// Drives a recursive `withObservationTracking` loop for `AppPreferencesStoreProtocol.pollingInterval`
/// entirely on the `@MainActor`. Because every method is `@MainActor`-isolated, the local
/// `func observe()` inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation
/// is required and no value crosses an isolation boundary.
///
/// - Note: `internal` visibility is intentional. Swift `private` is file-scoped, so moving
///   this class to a separate file from `RunnerPoller.swift` requires at least `internal`.
///   Cross-file access within the same module does not require `public` — `internal` is
///   sufficient and keeps this type invisible outside `RunnerBarCore`. Do not narrow to
///   `private` (breaks the cross-file reference) and do not widen to `public` (unnecessarily
///   expands the module API surface). `@testable import RunnerBarCore` exposes `internal`
///   symbols to the test target.
@MainActor
final class PreferencesObserver {
    /// The continuation used to push new `pollingInterval` values into the `AsyncStream`.
    ///
    /// **Stream element type is `TimeInterval` (Double), not `Int`.**
    /// `pollingInterval` is stored as `Int` (seconds) but is converted to `TimeInterval`
    /// via `TimeInterval(store.pollingInterval)` before yielding (see `start()` below).
    /// `RunnerPoller.startObservingPreferences` creates `AsyncStream<TimeInterval>.makeStream()`
    /// and passes the resulting `AsyncStream<TimeInterval>.Continuation` here — the types
    /// are consistent end-to-end.
    private let continuation: AsyncStream<TimeInterval>.Continuation
    /// The injected preferences store — avoids singleton access inside the observer.
    private let store: any AppPreferencesStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    ///
    /// - Parameters:
    ///   - continuation: Must be `AsyncStream<TimeInterval>.Continuation` — the observer
    ///     converts `pollingInterval: Int` to `TimeInterval` before each `yield`.
    ///   - store: The preferences store to observe.
    init(continuation: AsyncStream<TimeInterval>.Continuation, store: any AppPreferencesStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
    func start() {
        func observe() {
            withObservationTracking {
                _ = store.pollingInterval
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(TimeInterval(self.store.pollingInterval))
                    self.start()
                }
            }
        }
        observe()
    }
}

// MARK: - ScopesObserver

/// Drives a recursive `withObservationTracking` loop for `ScopeStoreProtocol.activeScopes`
/// entirely on the `@MainActor`. Same isolation rationale as `PreferencesObserver`.
///
/// - Note: `internal` visibility is intentional — see `PreferencesObserver` doc-comment
///   for the full rationale. Do not narrow to `private` or widen to `public`.
@MainActor
final class ScopesObserver {
    /// The continuation used to push new `activeScopes` values into the `AsyncStream`.
    private let continuation: AsyncStream<[String]>.Continuation
    /// The injected scope store — avoids singleton access inside the observer.
    private let store: any ScopeStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    init(continuation: AsyncStream<[String]>.Continuation, store: any ScopeStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
    func start() {
        func observe() {
            withObservationTracking {
                _ = store.activeScopes
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(self.store.activeScopes)
                    self.start()
                }
            }
        }
        observe()
    }
}
