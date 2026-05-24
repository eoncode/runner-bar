// RunnerBarCoreTests.swift
// RunnerBarCoreTests
import XCTest
@testable import RunnerBarCore

// MARK: - ActiveJob.elapsed

final class ActiveJobElapsedTests: XCTestCase {

    func testElapsedQueuedReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertEqual(job.elapsed, "00:00")
    }

    func testElapsedCompletedWithTimes() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 125)
        let job = ActiveJob(
            id: 1, name: "J", status: "completed",
            conclusion: "success",
            startedAt: start,
            completedAt: end
        )
        XCTAssertEqual(job.elapsed, "02:05")
    }

    func testElapsedCompletedMissingTimesReturnsDashes() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", conclusion: "success")
        XCTAssertEqual(job.elapsed, "--:--")
    }

    func testElapsedInProgressUsesStartedAt() {
        let start = Date(timeIntervalSinceNow: -90)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", startedAt: start)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        XCTAssertGreaterThanOrEqual(total, 89)
        XCTAssertLessThanOrEqual(total, 95)
    }

    func testElapsedInProgressFallsBackToCreatedAt() {
        // When startedAt is nil (still queued/assigning), elapsed uses createdAt
        let created = Date(timeIntervalSinceNow: -60)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", createdAt: created)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        XCTAssertGreaterThanOrEqual(total, 59)
        XCTAssertLessThanOrEqual(total, 65)
    }

    func testElapsedInProgressNeitherDateReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "in_progress")
        XCTAssertEqual(job.elapsed, "00:00")
    }
}

// MARK: - JobStep.elapsed

final class JobStepElapsedTests: XCTestCase {

    func testElapsedFixedDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 185) // 3m 5s
        let step = JobStep(id: 1, name: "S", status: "completed",
                           startedAt: start, completedAt: end)
        XCTAssertEqual(step.elapsed, "03:05")
    }

    func testElapsedNilDatesReturnsZero() {
        // Both nil → Date() - Date() ≈ 0
        let step = JobStep(id: 1, name: "S", status: "in_progress")
        XCTAssertEqual(step.elapsed, "00:00")
    }

    func testElapsedExactlyOneMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 60)
        let step = JobStep(id: 1, name: "S", status: "completed",
                           startedAt: start, completedAt: end)
        XCTAssertEqual(step.elapsed, "01:00")
    }
}

// MARK: - ActiveJob.isLocalRunner

final class ActiveJobIsLocalRunnerTests: XCTestCase {

    func testIsLocalRunnerNilWhenNoRunnerName() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertNil(job.isLocalRunner)
    }

    func testIsLocalRunnerFalseForUbuntuHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "ubuntu-latest")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerFalseForMacOSHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "macos-14")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerFalseForWindowsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "windows-2022")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerFalseForBuildjetHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "buildjet-4vcpu-ubuntu-2204")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerFalseForDepotHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "depot-ubuntu-22.04")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerFalseForGitHubActionsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "GitHub Actions 12")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    func testIsLocalRunnerTrueForSelfHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "my-mac-mini")
        XCTAssertEqual(job.isLocalRunner, true)
    }

    func testIsLocalRunnerTrueForCustomName() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "office-m2-runner")
        XCTAssertEqual(job.isLocalRunner, true)
    }
}

// MARK: - RunnerModel.displayStatus

final class RunnerModelDisplayStatusTests: XCTestCase {

    private func makeRunner(
        isRunning: Bool,
        isBusy: Bool = false,
        githubStatus: String = "online",
        lifecycleWarning: String? = nil
    ) -> RunnerModel {
        RunnerModel(
            runnerName: "test-runner",
            gitHubUrl: nil,
            agentId: nil,
            workFolder: nil,
            installPath: "/tmp/runner",
            isRunning: isRunning,
            githubStatus: githubStatus,
            isBusy: isBusy,
            lifecycleWarning: lifecycleWarning
        )
    }

    func testDisplayStatusRunning() {
        XCTAssertEqual(makeRunner(isRunning: true).displayStatus, "running")
    }

    // #773: displayStatus must return "busy" when isBusy is true (dead-branch fix).
    func testDisplayStatusBusy() {
        XCTAssertEqual(makeRunner(isRunning: true, isBusy: true).displayStatus, "busy")
    }

    func testDisplayStatusOnline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "online").displayStatus, "online")
    }

    func testDisplayStatusOffline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "offline").displayStatus, "offline")
    }

    func testDisplayStatusLifecycleWarningTakesPriority() {
        let runner = makeRunner(isRunning: true, lifecycleWarning: "update required")
        XCTAssertEqual(runner.displayStatus, "update required")
    }

    func testDisplayStatusBusyGithubStatusWhenNotRunning() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "busy").displayStatus, "busy")
    }

    func testDisplayStatusDefaultsToOfflineForUnknownStatus() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: "unknown").displayStatus, "offline")
    }
}

// MARK: - RunnerMetrics

final class RunnerMetricsTests: XCTestCase {

    func testEquatableSameValues() {
        let a = RunnerMetrics(cpu: 12.5, mem: 3.0)
        let b = RunnerMetrics(cpu: 12.5, mem: 3.0)
        XCTAssertEqual(a, b)
    }

    func testEquatableDifferentCPU() {
        let a = RunnerMetrics(cpu: 10.0, mem: 3.0)
        let b = RunnerMetrics(cpu: 20.0, mem: 3.0)
        XCTAssertNotEqual(a, b)
    }

    func testEquatableDifferentMem() {
        let a = RunnerMetrics(cpu: 10.0, mem: 1.0)
        let b = RunnerMetrics(cpu: 10.0, mem: 2.0)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - AggregateStatus

final class AggregateStatusTests: XCTestCase {

    func testDotAllOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.dot, "🟢")
    }

    func testDotSomeOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.dot, "🟡")
    }

    func testDotAllOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.dot, "⚫")
    }

    func testSymbolNameAllOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.symbolName, "circle.fill")
    }

    func testSymbolNameSomeOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.symbolName, "circle.lefthalf.filled")
    }

    func testSymbolNameAllOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.symbolName, "circle")
    }
}

// MARK: - PollResultBuilder (pure logic)

final class PollResultBuilderTests: XCTestCase {

    // MARK: trimJobCache

    func testTrimJobCacheRemovesOldestWhenOverLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 100)),
            2: ActiveJob(id: 2, name: "B", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 200)),
            3: ActiveJob(id: 3, name: "C", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 300)),
            4: ActiveJob(id: 4, name: "D", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 400)),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache[1], "Oldest entry should be evicted")
    }

    func testTrimJobCacheNoopWhenUnderLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed"),
            2: ActiveJob(id: 2, name: "B", status: "completed"),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: buildJobDisplay

    func testBuildJobDisplayLiveJobsFirst() {
        let live: [ActiveJob] = [
            ActiveJob(id: 10, name: "Live", status: "in_progress")
        ]
        let cache: [Int: ActiveJob] = [
            20: ActiveJob(id: 20, name: "Done", status: "completed", conclusion: "success")
        ]
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: cache)
        XCTAssertEqual(display.first?.id, 10)
        XCTAssertTrue(display.contains(where: { $0.id == 20 }))
    }

    func testBuildJobDisplayEmptyLiveAndCacheIsEmpty() {
        let display = PollResultBuilder.buildJobDisplay(live: [], cache: [:])
        XCTAssertTrue(display.isEmpty)
    }

    /// Verifies that live jobs beyond jobCacheLimit are NOT silently dropped.
    /// This was the bug in #776 — live jobs were capped at jobCacheLimit = 3.
    func testBuildJobDisplayDoesNotCapLiveJobsAtCacheLimit() {
        let live: [ActiveJob] = (1...5).map {
            ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
        }
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: [:])
        XCTAssertEqual(display.count, 5, "All 5 live jobs should appear; jobCacheLimit must not truncate live jobs")
    }

    /// Verifies the total display list is capped at jobDisplayLimit.
    func testBuildJobDisplayCapsAtJobDisplayLimit() {
        let live: [ActiveJob] = (1...8).map {
            ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
        }
        let cached: [Int: ActiveJob] = Dictionary(uniqueKeysWithValues: (100...106).map {
            ($0, ActiveJob(id: $0, name: "Done \($0)", status: "completed",
                           conclusion: "success",
                           completedAt: Date(timeIntervalSinceReferenceDate: Double($0))))
        })
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: cached)
        XCTAssertLessThanOrEqual(display.count, PollResultBuilder.jobDisplayLimit)
    }

    // MARK: applyVanishedJobs

    func testApplyVanishedJobsMovesVanishedJobToCache() {
        let vanished = ActiveJob(id: 55, name: "Vanished", status: "in_progress")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [55: vanished],
            liveIDs: [],
            now: Date(),
            into: &cache
        )
        XCTAssertNotNil(cache[55], "Vanished job should be added to cache")
        XCTAssertEqual(cache[55]?.status, "completed")
        XCTAssertEqual(cache[55]?.isDimmed, true)
        XCTAssertEqual(cache[55]?.conclusion, "success", "Missing conclusion defaults to success")
    }

    func testApplyVanishedJobsDoesNotOverwriteExistingCacheEntry() {
        let vanished = ActiveJob(id: 55, name: "Vanished", status: "in_progress")
        let existing = ActiveJob(id: 55, name: "Vanished", status: "completed",
                                 conclusion: "failure", isDimmed: true)
        var cache: [Int: ActiveJob] = [55: existing]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [55: vanished],
            liveIDs: [],
            now: Date(),
            into: &cache
        )
        XCTAssertEqual(cache[55]?.conclusion, "failure", "Existing cache entry must not be overwritten")
    }

    func testApplyVanishedJobsIgnoresStillLiveJobs() {
        let job = ActiveJob(id: 77, name: "StillLive", status: "in_progress")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [77: job],
            liveIDs: [77],
            now: Date(),
            into: &cache
        )
        XCTAssertNil(cache[77], "Live job must not be moved to cache")
    }

    func testApplyVanishedJobsPreservesExistingConclusion() {
        let vanished = ActiveJob(id: 88, name: "Done", status: "completed",
                                 conclusion: "failure")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [88: vanished],
            liveIDs: [],
            now: Date(),
            into: &cache
        )
        XCTAssertEqual(cache[88]?.conclusion, "failure", "Existing conclusion should be preserved")
    }

    // MARK: buildJobState

    func testBuildJobStateLiveJobAppearsInDisplay() {
        let liveJob = ActiveJob(id: 99, name: "CI", status: "in_progress")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [liveJob] },
            backfill: { _ in
                // No backfill needed for this test — step-log fetching
                // is exercised by integration tests, not unit tests.
            }
        )
        XCTAssertTrue(result.display.contains(where: { $0.id == 99 }))
    }

    func testBuildJobStateCompletedJobMovesToCache() {
        let doneJob = ActiveJob(id: 42, name: "Deploy", status: "completed", conclusion: "success")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [doneJob] },
            backfill: { _ in
                // No backfill needed — completed job already has full data.
            }
        )
        XCTAssertTrue(result.newCache.keys.contains(42))
        XCTAssertEqual(result.newCache[42]?.isDimmed, true)
    }

    func testBuildJobStateVanishedLiveJobAppearsInCache() {
        let prev = ActiveJob(id: 11, name: "Old", status: "in_progress")
        // Job 11 was live last poll but fetchJobs returns nothing this poll
        let result = PollResultBuilder.buildJobState(
            snapPrev: [11: prev],
            snapCache: [:],
            fetchJobs: { [] },
            backfill: { _ in
                // No backfill needed — vanished job has no new data to fetch.
            }
        )
        XCTAssertNotNil(result.newCache[11], "Vanished live job should appear in cache")
        XCTAssertEqual(result.newCache[11]?.status, "completed")
    }
}
