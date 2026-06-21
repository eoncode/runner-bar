// APICallCounterTests.swift
// RunnerBarCoreTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// Structure mirrors GitHubRateLimitActorTests.swift: @Suite / @Test / #expect,
// no shared mutable state, each test creates its own actor instance.
//
// The key invariants tested:
//   1. Fresh actor starts at zero.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
import Foundation
import Testing
@testable import RunnerBarCore

@Suite("APICallCounter")
struct APICallCounterTests {

    // MARK: - Defaults

    @Test("fresh actor starts at count zero")
    func freshActorStartsAtZero() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.count == 0)
        #expect(snap.limit == APICallCounter.hourlyLimit)
    }

    @Test("fresh actor fraction is zero")
    func freshActorFractionIsZero() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.fraction == 0.0)
    }

    // MARK: - record()

    @Test("record() increments count by one per call")
    func recordIncrementsCount() async {
        let counter = APICallCounter()
        await counter.record()
        await counter.record()
        await counter.record()
        let snap = await counter.snapshot()
        #expect(snap.count == 3)
    }

    @Test("record() from concurrent tasks all land in the count")
    func recordConcurrentTasks() async {
        let counter = APICallCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await counter.record() }
            }
        }
        let snap = await counter.snapshot()
        #expect(snap.count == 20)
    }

    // MARK: - fraction clamping

    @Test("fraction is clamped to 1.0 when count exceeds limit")
    func fractionClampedToOne() {
        let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 1.0)
    }

    @Test("fraction is exactly 0.5 at half the limit")
    func fractionAtHalf() {
        let snap = APICallCounterSnapshot(count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 0.5)
    }

    @Test("fraction stays within [0, 1] for any count")
    func fractionBounded() {
        for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
            let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
            #expect(snap.fraction >= 0.0)
            #expect(snap.fraction <= 1.0)
        }
    }

    // MARK: - snapshot atomicity (P10)

    @Test("snapshot returns consistent count + limit in a single hop")
    func snapshotIsConsistent() async {
        let counter = APICallCounter()
        await counter.record()
        let s1 = await counter.snapshot()
        let s2 = await counter.snapshot()
        #expect(s1 == s2)
    }

    @Test("snapshot limit always equals hourlyLimit constant")
    func snapshotLimitMatchesConstant() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.limit == APICallCounter.hourlyLimit)
    }

    // MARK: - APICallCounterSnapshot struct

    @Test("APICallCounterSnapshot is Equatable")
    func snapshotEquatable() {
        let a = APICallCounterSnapshot(count: 42, limit: 5_000)
        let b = APICallCounterSnapshot(count: 42, limit: 5_000)
        let c = APICallCounterSnapshot(count: 99, limit: 5_000)
        #expect(a == b)
        #expect(a != c)
    }

    /// Exercises `APICallCounterSnapshot`'s `Sendable` conformance at runtime
    /// by transferring a live snapshot across a `Task` boundary.
    @Test("APICallCounterSnapshot is Sendable across task boundary")
    func snapshotSendable() async throws {
        let counter = APICallCounter()
        await counter.record()
        await counter.record()
        let snap = await counter.snapshot()
        let transferred = try await Task.detached { snap }.value
        #expect(transferred.count == snap.count)
        #expect(transferred.limit == snap.limit)
    }
}
