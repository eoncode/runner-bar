// APICallCounterTests.swift
// RunnerBarCoreTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// The key invariants tested:
//   1. Fresh actor starts at zero.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
//   6. snapshot() returns zero after all timestamps expire (idle-gap regression).
//   7. ghAPI() / ghAPIPaginated() increment on non-nil AND skip on nil transport result.
//   8. record() trims buffer to hourlyLimit at >5,000 entries.
import Foundation
import Testing
@testable import RunnerBarCore

/// Stable endpoint string used by transport tests.
/// Extracted to avoid SonarCloud S1075 (hardcoded URI) on test call sites.
private let testEndpoint = "https://api.github.com/test"

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

    @Test("record() trims buffer to hourlyLimit when entries exceed it")
    func recordTrimsToHourlyLimit() async {
        let counter = APICallCounter()
        let now = Date()
        let fresh = (0..<(APICallCounter.hourlyLimit + 10)).map { now.addingTimeInterval(Double($0) * 0.001) }
        await counter.seed(timestamps: fresh)
        await counter.record()
        let snap = await counter.snapshot()
        #expect(snap.count == APICallCounter.hourlyLimit)
    }

    // MARK: - fraction clamping

    @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
    func fractionWithZeroLimitIsZero() {
        let snap = APICallCounterSnapshot(count: 42, limit: 0)
        #expect(snap.fraction == 0.0)
    }

    @Test("fraction is clamped to 1.0 when count exceeds limit")
    func fractionClampedToOne() {
        let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 1.0)
    }

    @Test("fraction is clamped to 0.0 when count is negative")
    func fractionClampedToZeroForNegativeCount() {
        let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
        #expect(snap.fraction == 0.0)
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

    /// Exercises the P10 atomicity guarantee under concurrent mutation.
    ///
    /// Fires `record()` calls concurrently from a task group while a second
    /// group calls `snapshot()` repeatedly. For every snapshot taken:
    /// - `limit` must always equal `hourlyLimit` (compile-time constant;
    ///   any torn two-hop read would be detectable here).
    /// - `count` must be within `[0, hourlyLimit]` (bounded by the trim cap).
    /// - `fraction` must be within `[0, 1]`.
    @Test("snapshot() count+limit are consistent under concurrent record() mutations")
    func snapshotAtomicUnderConcurrentMutations() async {
        let counter = APICallCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { await counter.record() }
            }
            for _ in 0..<20 {
                group.addTask {
                    let snap = await counter.snapshot()
                    #expect(snap.limit == APICallCounter.hourlyLimit)
                    #expect(snap.count <= APICallCounter.hourlyLimit)
                    #expect(snap.fraction >= 0.0)
                    #expect(snap.fraction <= 1.0)
                }
            }
        }
    }

    @Test("snapshot limit always equals hourlyLimit constant")
    func snapshotLimitMatchesConstant() async {
        let counter = APICallCounter()
        let snap = await counter.snapshot()
        #expect(snap.limit == APICallCounter.hourlyLimit)
    }

    // MARK: - Idle-gap regression

    @Test("snapshot() returns zero after all timestamps expire without a record() call")
    func snapshotPurgesIdleStaleEntries() async {
        let counter = APICallCounter()
        let stale = Date().addingTimeInterval(-5_400)
        await counter.seed(timestamps: [stale, stale])
        let snap = await counter.snapshot()
        #expect(snap.count == 0)
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

    /// Compile-time conformance check for `APICallCounterSnapshot.Sendable`.
    @Test("APICallCounterSnapshot is Sendable across task boundary")
    func snapshotSendable() async {
        let counter = APICallCounter()
        await counter.record()
        await counter.record()
        let snap = await counter.snapshot()
        let transferred = await Task.detached { snap }.value
        #expect(transferred.count == snap.count)
        #expect(transferred.limit == snap.limit)
    }

    // MARK: - Transport increment guard

    /// Serialized sub-suite for all tests that touch module-level singletons
    /// (`apiCallCounter`, `configureGHAPI`, `configureGHAPIPaginated`).
    ///
    /// `.serialized` prevents Swift Testing from scheduling these concurrently,
    /// eliminating the reset()+call+snapshot interleaving race that the
    /// `// Note:` caveats in each test document. See issue #1511 for the
    /// follow-up to make `apiCallCounter` overridable and remove this constraint.
    @Suite("Transport increment guard", .serialized)
    struct TransportIncrementGuard {

        /// Asserts that `ghAPI()` **does** increment the counter when the
        /// transport returns non-nil data.
        ///
        /// This is the positive-path complement to `ghAPISkipsCounterOnNilResult`.
        /// If the `if result != nil { await apiCallCounter.record() }` guard
        /// were silently dropped from `ghAPI()`, this test would fail.
        @Test("ghAPI() increments counter when transport returns non-nil data")
        func ghAPIIncrementsCounterOnNonNilResult() async {
            await apiCallCounter.reset()
            configureGHAPI { _ in Data() }
            _ = await ghAPI(testEndpoint)
            let snap = await apiCallCounter.snapshot()
            #expect(snap.count == 1)
            configureGHAPI { _ in nil }
        }

        /// Asserts that `ghAPIPaginated()` **does** increment the counter when
        /// the transport returns non-nil data.
        ///
        /// Symmetric positive-path complement to `ghAPIPaginatedSkipsCounterOnNilResult`.
        @Test("ghAPIPaginated() increments counter when transport returns non-nil data")
        func ghAPIPaginatedIncrementsCounterOnNonNilResult() async {
            await apiCallCounter.reset()
            configureGHAPIPaginated { _, _ in Data() }
            _ = await ghAPIPaginated(testEndpoint)
            let snap = await apiCallCounter.snapshot()
            #expect(snap.count == 1)
            configureGHAPIPaginated { _, _ in nil }
        }

        /// Asserts that `ghAPI()` does **not** increment the counter when the
        /// transport returns `nil`.
        ///
        /// - Note: Mutates `APICallCounter.shared`. Serialized via parent suite
        ///   trait to prevent concurrent interleaving. See issue #1511.
        @Test("ghAPI() does not increment counter when transport returns nil")
        func ghAPISkipsCounterOnNilResult() async {
            await apiCallCounter.reset()
            configureGHAPI { _ in nil }
            _ = await ghAPI(testEndpoint)
            let snap = await apiCallCounter.snapshot()
            #expect(snap.count == 0)
            configureGHAPI { _ in nil }
        }

        /// Asserts that `ghAPIPaginated()` does **not** increment the counter
        /// when the transport returns `nil`.
        ///
        /// - Note: Mutates `APICallCounter.shared`. Serialized via parent suite
        ///   trait to prevent concurrent interleaving. See issue #1511.
        @Test("ghAPIPaginated() does not increment counter when transport returns nil")
        func ghAPIPaginatedSkipsCounterOnNilResult() async {
            await apiCallCounter.reset()
            configureGHAPIPaginated { _, _ in nil }
            _ = await ghAPIPaginated(testEndpoint)
            let snap = await apiCallCounter.snapshot()
            #expect(snap.count == 0)
            configureGHAPIPaginated { _, _ in nil }
        }
    }
}
