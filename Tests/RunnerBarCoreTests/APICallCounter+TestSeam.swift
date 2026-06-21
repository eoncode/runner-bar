// APICallCounter+TestSeam.swift
// RunnerBarCoreTests
//
// Test-only extension that adds a time-injection seam to APICallCounter.
//
// Kept in Tests/ rather than behind #if DEBUG in the source target so that
// SwiftPM always compiles it for the test target without requiring a DEBUG
// condition to be defined for the RunnerBarCore library target.
import Foundation
@testable import RunnerBarCore

extension APICallCounter {
    /// Directly replaces the internal timestamp buffer.
    ///
    /// **For testing only.** Allows unit tests to inject pre-aged timestamps
    /// without sleeping for real time, enabling deterministic verification of
    /// the idle-gap purge behaviour in `snapshot()`.
    ///
    /// - Parameter timestamps: The replacement timestamp array. Pass dates in
    ///   the past to simulate stale entries, or in the future for edge-case tests.
    func seed(timestamps injected: [Date]) {
        timestamps = injected
    }
}
