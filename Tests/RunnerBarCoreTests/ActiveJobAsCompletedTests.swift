// ActiveJobAsCompletedTests.swift
// RunnerBarCoreTests
import XCTest
@testable import RunnerBarCore

final class ActiveJobAsCompletedTests: XCTestCase {

    private let fallback = Date(timeIntervalSince1970: 1_000)
    private let existing = Date(timeIntervalSince1970: 500)
    private let queued  = Date(timeIntervalSince1970: 100)

    // MARK: Helpers

    private func makeJob(
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        conclusion: JobConclusion? = nil
    ) -> ActiveJob {
        ActiveJob(
            id: 42,
            name: "build",
            status: .inProgress,
            conclusion: conclusion,
            completedAt: completedAt,
            createdAt: createdAt
        )
    }

    // MARK: Tests

    /// When the job already has a completedAt, asCompleted(at:) must ignore the fallback.
    func test_asCompleted_existingCompletedAt_fallbackIgnored() {
        let job = makeJob(completedAt: existing)
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.completedAt, existing)
    }

    /// When completedAt is nil, asCompleted(at:) must use the fallback date.
    func test_asCompleted_nilCompletedAt_fallbackUsed() {
        let job = makeJob(completedAt: nil)
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.completedAt, fallback)
    }

    /// createdAt must be preserved verbatim so that elapsed display works for
    /// queued-only jobs (where startedAt is nil and createdAt is the only timing field).
    func test_asCompleted_createdAtPreserved() {
        let job = makeJob(createdAt: queued)
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.createdAt, queued)
    }

    /// Confirm that status and isDimmed are always set to their expected values.
    func test_asCompleted_statusAndDimmedAlwaysSet() {
        let job = makeJob()
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(result.isDimmed)
    }

    /// When the source job has no conclusion, asCompleted(at:) must default to .cancelled.
    func test_asCompleted_nilConclusion_defaultsToCancelled() {
        let job = makeJob(conclusion: nil)
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.conclusion, .cancelled)
    }

    /// When the source job has a recorded conclusion, it must be preserved.
    func test_asCompleted_existingConclusion_preserved() {
        let job = makeJob(conclusion: .success)
        let result = job.asCompleted(at: fallback)
        XCTAssertEqual(result.conclusion, .success)
    }
}
