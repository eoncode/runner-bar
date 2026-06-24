// RunnerPollerProtocol.swift
// RunnerBarCore

// MARK: - RunnerPollerProtocol

/// Minimal interface for the GitHub poll-loop actor.
///
/// Typed as `any RunnerPollerProtocol` in `AppDelegate` so future tests can
/// substitute a `MockPoller` without importing the RunnerBar app target.
public protocol RunnerPollerProtocol: AnyObject {
    /// Starts the poll loop, observers, and initial fetch.
    func start() async
}

// MARK: - Conformance

/// `RunnerPoller` is the production implementation of `RunnerPollerProtocol`.
extension RunnerPoller: RunnerPollerProtocol {}
