// RunnerBarCoreTests.swift
// RunnerBarCoreTests
import Collections
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - PollResultBuilder tests

@Suite struct PollResultBuilderTests {

    // MARK: trimSeenGroupIDs

    /// Empty set must remain empty.
    @Test func trimSeenGroupIDsEmpty() {
        var ids: OrderedSet<String> = []
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        #expect(ids.isEmpty)
    }

    /// Set at exactly the limit must not be modified.
    @Test func trimSeenGroupIDsNoopAtLimit() {
        var ids: OrderedSet<String> = OrderedSet((1...10).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        #expect(ids.count == 10)
    }

    /// Set below the limit must not be modified.
    @Test func trimSeenGroupIDsNoopBelowLimit() {
        var ids: OrderedSet<String> = ["a", "b", "c"]
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        #expect(ids.count == 3)
    }

    /// Oldest entries (lowest indices) must be evicted first — FIFO.
    ///
    /// Inserts 12 IDs in order ("group-1" … "group-12"), then trims to 10.
    /// The two oldest ("group-1", "group-2") must be gone; the ten newest must remain
    /// in insertion order.
    @Test func trimSeenGroupIDsEvictsOldestFirst() {
        var ids: OrderedSet<String> = OrderedSet((1...12).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        #expect(ids.count == 10)
        #expect(!ids.contains("group-1"))
        #expect(!ids.contains("group-2"))
        #expect(ids.first == "group-3")
        #expect(ids.last == "group-12")
    }
}
