// APICallCounterViewModel.swift
// RunnerBar
//
// @Observable view-model exposing live GitHub API call-counter state
// for the Settings panel (P2 — Async/Await and @Observable for Data Flow).
import Foundation
import Observation
import RunnerBarCore
import SwiftUI

// MARK: - TaskBox

/// Reference-type wrapper that holds a cancellable polling `Task`.
///
/// `@Observable` expands stored properties via `@ObservationTracked`.
/// Neither `nonisolated` nor `nonisolated(unsafe)` compiles cleanly on
/// such a property in a `@MainActor` class under Swift 6 strict concurrency.
/// Wrapping the task in a `final class` makes it opaque to the macro.
/// `deinit` can then call `taskBox.task?.cancel()` without an isolation
/// violation because `TaskBox` is `@unchecked Sendable` — safe here
/// because it is only ever written from `@MainActor` context.
///
/// - TODO: Revisit when `@Observable` supports `nonisolated` task storage
///   natively (tracked in Swift Evolution). At that point `TaskBox` can be
///   replaced with a plain `nonisolated var pollingTask: Task<Void, Never>?`.
private final class TaskBox: @unchecked Sendable {
    /// The structured polling task, or `nil` before polling has started.
    /// Invariant: must only be written from `@MainActor` context.
    var task: Task<Void, Never>?
    /// Creates an empty `TaskBox` with no active polling task.
    init() {}
}

// MARK: - APICallCounterViewModel

/// View-model that polls `APICallCounterProtocol` every 5 seconds and
/// exposes derived display state for `APICallCounterRow`.
@Observable
@MainActor
public final class APICallCounterViewModel {
    /// Latest atomic snapshot from the counter actor.
    public private(set) var snap = APICallCounterSnapshot(
        count: 0,
        limit: APICallCounter.hourlyLimit
    )

    /// The counter actor injected at init time (P7).
    private let counter: any APICallCounterProtocol

    /// Box holding the structured polling task so `deinit` can cancel it.
    private let taskBox = TaskBox()

    /// Creates the view-model.
    /// - Parameter counter: Counter to poll. Defaults to `apiCallCounter`.
    public init(counter: any APICallCounterProtocol = apiCallCounter) {
        self.counter = counter
        startPolling()
    }

    deinit { taskBox.task?.cancel() }

    // MARK: - Derived display state

    /// Human-readable counter label, e.g. `"410 / 5,000"`.
    public var label: String {
        "\(snap.count.formatted()) / \(snap.limit.formatted())"
    }

    /// Progress bar and counter tint: green → yellow → red as usage rises.
    public var statusColor: Color {
        switch snap.fraction {
        case ..<0.60: .green
        case ..<0.85: .yellow
        default: .red
        }
    }

    // MARK: - Private

    /// Starts a structured polling loop that refreshes `snap` every 5 seconds.
    ///
    /// Uses `do { try await Task.sleep } catch { return }` rather than `try?`
    /// so that a `CancellationError` from `deinit` exits the loop immediately
    /// without waiting for the full sleep window to complete.
    private func startPolling() {
        taskBox.task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.snap = await self.counter.snapshot()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }
}
