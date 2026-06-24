// ObservationLoopTests.swift
// RunnerBarCoreTests
//
// Unit tests for ObservationLoop.
//
// Invariants tested:
//   1. onChange fires when an @Observable property changes.
//   2. onChange fires again on a second mutation (re-registration works).
//   3. onChange does NOT fire after the loop is deallocated.
//   4. onChange does NOT fire when an untracked property on the same object changes.
import Foundation
import Testing
import Observation
@testable import RunnerBarCore

@MainActor
@Observable
final class ObservableCounter {
    var count = 0
    /// Second property — used by test 4 to verify that mutating an untracked
    /// property does not trigger an onChange that only reads `count`.
    var label = ""
}

@Suite("ObservationLoop")
@MainActor
struct ObservationLoopTests {

    @Test("onChange fires when observed property changes")
    func firesOnChange() async throws {
        let counter = ObservableCounter()
        var fired = 0

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        counter.count = 1
        // 10 ms sleep gives the enqueued @MainActor task from ObservationLoop.register()
        // time to drain. A single Task.yield() is not a guaranteed drain — the
        // withObservationTracking onChange callback is enqueued as a new Task on the
        // main actor executor and may not have run after a single yield point.
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(fired == 1)
        _ = loop // keep alive
    }

    @Test("onChange fires again on second mutation — re-registration works")
    func firesOnSecondMutation() async throws {
        let counter = ObservableCounter()
        var fired = 0

        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        counter.count = 1
        try await Task.sleep(nanoseconds: 10_000_000)
        counter.count = 2
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(fired == 2)
        _ = loop
    }

    @Test("onChange does not fire after loop is deallocated")
    func doesNotFireAfterDealloc() async throws {
        let counter = ObservableCounter()
        var fired = 0

        var loop: ObservationLoop? = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        // `isolated deinit` on ObservationLoop guarantees isRunning = false is written
        // on @MainActor — the same executor we're on now. The nil assignment therefore
        // synchronously completes the deinit before the mutation below runs, making the
        // guard in register()'s Task body fire before any onChange can be enqueued.
        // This test is the canary that breaks if `isolated deinit` is accidentally removed.
        loop = nil
        counter.count = 1
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(fired == 0)
    }

    @Test("onChange does not fire when an untracked property changes")
    func doesNotFireForUntrackedProperty() async throws {
        let counter = ObservableCounter()
        var fired = 0

        // observe reads only `count` — `label` is not tracked.
        let loop = ObservationLoop {
            _ = counter.count
        } onChange: {
            fired += 1
        }

        // Mutate only the untracked property.
        counter.label = "hello"
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(fired == 0)
        _ = loop // keep alive
    }
}
