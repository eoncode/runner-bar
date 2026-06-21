// APICallCounterViewModel.swift
// RunnerBar
//
// @Observable view-model that exposes live GitHub API call-counter state
// for the Settings panel (P2 — Async/Await and @Observable for Data Flow).
//
// Injects `any APICallCounterProtocol` (P7 — Protocol-Oriented DI) so the
// view can be driven by a spy in unit tests without touching the real actor.
//
// Polling uses Task + Task.sleep(for:) (P9 — Structured Concurrency for
// Stateful Timers), not DispatchQueue.asyncAfter.
import Foundation
import Observation
import RunnerBarCore
import SwiftUI

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

    /// The counter actor. Defaulted to the shared production instance;
    /// override in tests via the initialiser.
    private let counter: any APICallCounterProtocol

    /// Structured polling task. Cancelled in `deinit`.
    ///
    /// Marked `nonisolated(unsafe)` because Swift 6 treats `deinit` as
    /// nonisolated and therefore cannot read a `@MainActor`-isolated
    /// stored property. This property is only ever written from
    /// `@MainActor` context (`init` → `startPolling()`), so the
    /// annotation is correct and the unsafety is bounded.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    /// Creates the view-model.
    ///
    /// - Parameter counter: Counter actor to poll. Defaults to the shared
    ///   production `apiCallCounter`.
    public init(counter: any APICallCounterProtocol = apiCallCounter) {
        self.counter = counter
        startPolling()
    }

    deinit { pollTask?.cancel() }

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
    /// Uses `[weak self]` to avoid retaining the view-model after the owning
    /// view has been deallocated. `Task.isCancelled` is checked before each
    /// sleep so cancellation from `deinit` is honoured promptly.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.snap = await self.counter.snapshot()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
