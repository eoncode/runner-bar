// PollLoopCoordinator.swift
// RunnerBar
import Foundation

// MARK: - PollLoopCoordinator

/// Owns the three `Task` handles that drive `RunnerStore`’s poll loop.
///
/// `RunnerStore` holds this as a stored property, so all access is serialised
/// by the actor’s own executor — no additional isolation annotation is needed.
///
/// **Why a dedicated type?**
/// Swift’s `private` modifier is file-scoped, not type-scoped. The poll-loop
/// state (`pollTask`, `intervalObservationTask`, `scopeObservationTask`) cannot
/// be moved into `RunnerStore+PollLoop.swift` as raw stored properties without
/// widening their access to `internal`. Wrapping them here makes the coordinator
/// itself `internal` while keeping the individual task slots effectively private
/// to this file.
final class PollLoopCoordinator {

    // MARK: - Stored task handles

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private(set) var pollTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `pollingInterval` changes.
    private(set) var intervalObservationTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `activeScopes` changes.
    private(set) var scopeObservationTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new coordinator with all task handles set to `nil`.
    init() {}

    deinit { cancelAll() }

    // MARK: - Mutation

    /// Replaces the active poll task, cancelling the previous one first.
    func setPollTask(_ task: Task<Void, Never>?) {
        pollTask?.cancel()
        pollTask = task
    }

    /// Replaces the interval-observation task, cancelling the previous one first.
    func setIntervalObservationTask(_ task: Task<Void, Never>?) {
        intervalObservationTask?.cancel()
        intervalObservationTask = task
    }

    /// Replaces the scope-observation task, cancelling the previous one first.
    func setScopeObservationTask(_ task: Task<Void, Never>?) {
        scopeObservationTask?.cancel()
        scopeObservationTask = task
    }

    /// Cancels all three tasks. Called from `RunnerStore.deinit` and this type’s own `deinit`.
    func cancelAll() {
        pollTask?.cancel()
        intervalObservationTask?.cancel()
        scopeObservationTask?.cancel()
    }
}
