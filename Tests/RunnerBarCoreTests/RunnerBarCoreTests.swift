// RunnerBarCoreTests.swift
// RunnerBarCoreTests
import XCTest
@testable import RunnerBarCore

// MARK: - ActiveJob.elapsed

final class ActiveJobElapsedTests: XCTestCase {

    /// Verifies that a queued job (never started) returns "00:00" elapsed time.
    func testElapsedQueuedReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertEqual(job.elapsed, "00:00")
    }

    /// Verifies that elapsed time is formatted as "MM:SS" when start and end dates are provided for a completed job.
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

    /// Verifies that a completed job without timestamps returns "--:--" as elapsed time.
    func testElapsedCompletedMissingTimesReturnsDashes() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", conclusion: "success")
        XCTAssertEqual(job.elapsed, "--:--")
    }

    /// Verifies that an in-progress job calculates elapsed time from startedAt to now, within a reasonable tolerance.
    func testElapsedInProgressUsesStartedAt() {
        let start = Date(timeIntervalSinceNow: -90)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", startedAt: start)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        XCTAssertGreaterThanOrEqual(total, 89)
        XCTAssertLessThanOrEqual(total, 95)
    }

    /// Verifies that an in-progress job falls back to createdAt when startedAt is nil (still queued/assigning).
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

    /// Verifies that an in-progress job with neither startedAt nor createdAt returns "00:00".
    func testElapsedInProgressNeitherDateReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "in_progress")
        XCTAssertEqual(job.elapsed, "00:00")
    }
}

// MARK: - JobStep.elapsed

final class JobStepElapsedTests: XCTestCase {

    /// Verifies that a completed job step formats elapsed time as "MM:SS" given fixed start/end dates.
    func testElapsedFixedDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 185) // 3m 5s
        let step = JobStep(id: 1, name: "S", status: "completed",
                           startedAt: start, completedAt: end)
        XCTAssertEqual(step.elapsed, "03:05")
    }

    /// Verifies that a step with nil start and end dates returns "00:00".
    func testElapsedNilDatesReturnsZero() {
        // Both nil → Date() - Date() ≈ 0
        let step = JobStep(id: 1, name: "S", status: "in_progress")
        XCTAssertEqual(step.elapsed, "00:00")
    }

    /// Verifies that exactly one minute (60 seconds) is formatted as "01:00".
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

    /// Verifies that isLocalRunner returns nil when a job has no runner name.
    func testIsLocalRunnerNilWhenNoRunnerName() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        XCTAssertNil(job.isLocalRunner)
    }

    /// Verifies that a GitHub-hosted Ubuntu runner is not considered local.
    func testIsLocalRunnerFalseForUbuntuHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "ubuntu-latest")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that a GitHub-hosted macOS runner is not considered local.
    func testIsLocalRunnerFalseForMacOSHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "macos-14")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that a GitHub-hosted Windows runner is not considered local.
    func testIsLocalRunnerFalseForWindowsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "windows-2022")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that a buildjet-hosted runner is not considered local.
    func testIsLocalRunnerFalseForBuildjetHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "buildjet-4vcpu-ubuntu-2204")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that a depot-hosted runner is not considered local.
    func testIsLocalRunnerFalseForDepotHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "depot-ubuntu-22.04")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that a runner named "GitHub Actions 12" (hosted by GitHub) is not considered local.
    func testIsLocalRunnerFalseForGitHubActionsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "GitHub Actions 12")
        XCTAssertEqual(job.isLocalRunner, false)
    }

    /// Verifies that an arbitrary self-hosted runner name is identified as local.
    func testIsLocalRunnerTrueForSelfHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "my-mac-mini")
        XCTAssertEqual(job.isLocalRunner, true)
    }

    /// Verifies that a custom-named runner (e.g., "office-m2-runner") is identified as local.
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
        githubStatus: RunnerStatus = .online,
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

    /// Verifies that a running runner displays "running" status.
    func testDisplayStatusRunning() {
        XCTAssertEqual(makeRunner(isRunning: true).displayStatus, "running")
    }

    /// Verifies that a runner with isBusy = true displays "busy" status (dead-branch fix for #773).
    func testDisplayStatusBusy() {
        XCTAssertEqual(makeRunner(isRunning: true, isBusy: true).displayStatus, "busy")
    }

    /// Verifies that a non-running runner with GitHub status .online displays "online".
    func testDisplayStatusOnline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .online).displayStatus, "online")
    }

    /// Verifies that a non-running runner with GitHub status .offline displays "offline".
    func testDisplayStatusOffline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .offline).displayStatus, "offline")
    }

    /// Verifies that a lifecycle warning overrides the running/busy status.
    func testDisplayStatusLifecycleWarningTakesPriority() {
        let runner = makeRunner(isRunning: true, lifecycleWarning: "update required")
        XCTAssertEqual(runner.displayStatus, "update required")
    }

    /// Verifies that a non-running runner with GitHub status .busy displays "busy".
    func testDisplayStatusBusyGithubStatusWhenNotRunning() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .busy).displayStatus, "busy")
    }

    /// Verifies that a non-running runner with an unknown GitHub status defaults to "offline".
    func testDisplayStatusDefaultsToOfflineForUnknownStatus() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .unknown("draining")).displayStatus, "offline")
    }
}

// MARK: - RunnerModel.statusColor

final class RunnerModelStatusColorTests: XCTestCase {

    private func makeRunner(
        isRunning: Bool,
        isBusy: Bool = false,
        githubStatus: RunnerStatus = .online,
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

    /// Verifies that a running, non-busy runner gets the .running dot colour.
    func testStatusColorRunning() {
        XCTAssertEqual(makeRunner(isRunning: true).statusColor, .running)
    }

    /// Verifies that a running and busy runner gets the .busy dot colour.
    func testStatusColorBusy() {
        XCTAssertEqual(makeRunner(isRunning: true, isBusy: true).statusColor, .busy)
    }

    /// Verifies that a non-running runner that GitHub reports as online gets the .idle dot colour.
    func testStatusColorGithubOnlineIsIdle() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .online).statusColor, .idle)
    }

    /// Verifies that a non-running runner with an offline GitHub status gets the .offline dot colour.
    func testStatusColorOffline() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .offline).statusColor, .offline)
    }

    /// Verifies that a lifecycle warning maps to the .offline dot colour.
    func testStatusColorLifecycleWarning() {
        XCTAssertEqual(makeRunner(isRunning: true, lifecycleWarning: "restart failed").statusColor, .offline)
    }

    /// Verifies that an unknown GitHub status (not running locally) maps to .offline.
    func testStatusColorUnknownGithubStatus() {
        XCTAssertEqual(makeRunner(isRunning: false, githubStatus: .unknown("draining")).statusColor, .offline)
    }
}

// MARK: - Runner.displayStatus

final class RunnerDisplayStatusTests: XCTestCase {

    private func makeRunner(status: RunnerStatus, busy: Bool = false, metrics: RunnerMetrics? = nil) -> Runner {
        Runner(id: 1, name: "r", status: status, busy: busy, metrics: metrics)
    }

    /// Verifies that an offline runner returns "offline".
    func testOfflineReturnsOffline() {
        XCTAssertEqual(makeRunner(status: .offline).displayStatus, "offline")
    }

    /// Verifies that an unknown status returns "offline" (not idle/active).
    func testUnknownReturnsOffline() {
        XCTAssertEqual(makeRunner(status: .unknown("draining")).displayStatus, "offline")
    }

    /// Verifies that an online, non-busy runner with no metrics returns the idle placeholder.
    func testOnlineIdleNoMetrics() {
        XCTAssertEqual(makeRunner(status: .online, busy: false).displayStatus, "idle (CPU: — MEM: —)")
    }

    /// Verifies that an online, busy runner with metrics returns the active format.
    func testOnlineBusyWithMetrics() {
        let m = RunnerMetrics(cpu: 45.0, mem: 12.3)
        XCTAssertEqual(makeRunner(status: .online, busy: true, metrics: m).displayStatus, "active (CPU: 45.0% MEM: 12.3%)")
    }

    /// Verifies that a busy status (from API) is treated same as online for display.
    func testBusyStatusShowsActiveWithMetrics() {
        let m = RunnerMetrics(cpu: 80.0, mem: 50.0)
        XCTAssertEqual(makeRunner(status: .busy, busy: true, metrics: m).displayStatus, "active (CPU: 80.0% MEM: 50.0%)")
    }
}

// MARK: - RunnerMetrics

final class RunnerMetricsTests: XCTestCase {

    /// Verifies that two RunnerMetrics with identical CPU and memory values are considered equal.
    func testEquatableSameValues() {
        let a = RunnerMetrics(cpu: 12.5, mem: 3.0)
        let b = RunnerMetrics(cpu: 12.5, mem: 3.0)
        XCTAssertEqual(a, b)
    }

    /// Verifies that two RunnerMetrics with different CPU values are considered not equal.
    func testEquatableDifferentCPU() {
        let a = RunnerMetrics(cpu: 10.0, mem: 3.0)
        let b = RunnerMetrics(cpu: 20.0, mem: 3.0)
        XCTAssertNotEqual(a, b)
    }

    /// Verifies that two RunnerMetrics with different memory values are considered not equal.
    func testEquatableDifferentMem() {
        let a = RunnerMetrics(cpu: 10.0, mem: 1.0)
        let b = RunnerMetrics(cpu: 10.0, mem: 2.0)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - AggregateStatus

final class AggregateStatusTests: XCTestCase {

    /// Verifies that allOnline status returns the green circle dot character.
    func testDotAllOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.dot, "🟢")
    }

    /// Verifies that someOffline status returns the yellow circle dot character.
    func testDotSomeOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.dot, "🟡")
    }

    /// Verifies that allOffline status returns the black circle dot character.
    func testDotAllOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.dot, "⚫")
    }

    /// Verifies that allOnline status maps to the SF Symbol "circle.fill".
    func testSymbolNameAllOnline() {
        XCTAssertEqual(AggregateStatus.allOnline.symbolName, "circle.fill")
    }

    /// Verifies that someOffline status maps to the SF Symbol "circle.lefthalf.filled".
    func testSymbolNameSomeOffline() {
        XCTAssertEqual(AggregateStatus.someOffline.symbolName, "circle.lefthalf.filled")
    }

    /// Verifies that allOffline status maps to the SF Symbol "circle".
    func testSymbolNameAllOffline() {
        XCTAssertEqual(AggregateStatus.allOffline.symbolName, "circle")
    }
}

// MARK: - PollResultBuilder (pure logic)

final class PollResultBuilderTests: XCTestCase {

    // MARK: trimJobCache

    /// Verifies that trimJobCache removes the oldest completed job entries when the cache exceeds the given limit.
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

    /// Verifies that trimJobCache does nothing when the cache is already under the limit.
    func testTrimJobCacheNoopWhenUnderLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed"),
            2: ActiveJob(id: 2, name: "B", status: "completed"),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: buildJobDisplay

    /// Verifies that buildJobDisplay places live (in-progress) jobs before cached (completed) jobs in the display list.
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

    /// Verifies that buildJobDisplay returns an empty array when both live and cache are empty.
    func testBuildJobDisplayEmptyLiveAndCacheIsEmpty() {
        let display = PollResultBuilder.buildJobDisplay(live: [], cache: [:])
        XCTAssertTrue(display.isEmpty)
    }

    /// Verifies that live jobs beyond jobCacheLimit (3) are NOT silently dropped (bug fix for #776).
    func testBuildJobDisplayDoesNotCapLiveJobsAtCacheLimit() {
        let live: [ActiveJob] = (1...5).map {
            ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
        }
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: [:])
        XCTAssertEqual(display.count, 5, "All 5 live jobs should appear; jobCacheLimit must not truncate live jobs")
    }

    /// Verifies that the total display list is capped at jobDisplayLimit (8).
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

    /// Verifies that a job present in the previous snapshot but missing from live results is moved to the cache with "completed" status and dimmed.
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

    /// Verifies that an existing cached entry for a vanished job is not overwritten by the vanish logic.
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

    /// Verifies that jobs still present in the live list are NOT moved to the cache.
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

    /// Verifies that a vanished job with an existing conclusion (e.g., "failure") preserves that conclusion in the cache.
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

    /// Verifies that a live job from fetchJobs appears in the display list of the returned job state.
    func testBuildJobStateLiveJobAppearsInDisplay() {
        let liveJob = ActiveJob(id: 99, name: "CI", status: "in_progress")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [liveJob] },
            backfill: { _ in }
        )
        XCTAssertTrue(result.display.contains(where: { $0.id == 99 }))
    }

    /// Verifies that a completed job from fetchJobs is moved to the cache and marked as dimmed.
    func testBuildJobStateCompletedJobMovesToCache() {
        let doneJob = ActiveJob(id: 42, name: "Deploy", status: "completed", conclusion: "success")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [doneJob] },
            backfill: { _ in }
        )
        XCTAssertTrue(result.newCache.keys.contains(42))
        XCTAssertEqual(result.newCache[42]?.isDimmed, true)
    }

    /// Verifies that a job that was live in the previous poll but is absent from fetchJobs is moved to the cache as vanished.
    func testBuildJobStateVanishedLiveJobAppearsInCache() {
        let prev = ActiveJob(id: 11, name: "Old", status: "in_progress")
        let result = PollResultBuilder.buildJobState(
            snapPrev: [11: prev],
            snapCache: [:],
            fetchJobs: { [] },
            backfill: { _ in }
        )
        XCTAssertNotNil(result.newCache[11], "Vanished live job should appear in cache")
        XCTAssertEqual(result.newCache[11]?.status, "completed")
    }

    // MARK: trimSeenGroupIDs

    /// Set at exactly the limit must not be modified.
    func testTrimSeenGroupIDsNoopAtLimit() {
        var ids: Set<String> = Set((1...10).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        XCTAssertEqual(ids.count, 10, "Set at exactly the limit must not be trimmed")
    }

    /// One entry over the limit: must leave exactly `limit` entries, not `limit/2`.
    ///
    /// Guards against the off-by-half bug where `ids.count - limit/2` removes
    /// too many entries and the set oscillates between limit/2 and limit.
    func testTrimSeenGroupIDsTrimsToLimitNotHalf() {
        let limit = 10
        var ids: Set<String> = Set((1...(limit + 1)).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
        XCTAssertEqual(ids.count, limit,
            "One entry over limit must trim to exactly limit, not limit/2 (\(limit / 2))")
    }

    /// Well over the limit: must also leave exactly `limit` entries.
    func testTrimSeenGroupIDsWellOverLimit() {
        let limit = 10
        var ids: Set<String> = Set((1...25).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
        XCTAssertEqual(ids.count, limit,
            "Set well over limit must trim to exactly limit entries")
    }
}

// MARK: - JobStatus.isActive

final class JobStatusIsActiveTests: XCTestCase {

    /// Verifies that queued, inProgress, waiting, requested, and pending are all active.
    func testActiveStatuses() {
        XCTAssertTrue(JobStatus.queued.isActive)
        XCTAssertTrue(JobStatus.inProgress.isActive)
        XCTAssertTrue(JobStatus.waiting.isActive)
        XCTAssertTrue(JobStatus.requested.isActive)
        XCTAssertTrue(JobStatus.pending.isActive)
    }

    /// Verifies that completed is not active.
    func testCompletedIsNotActive() {
        XCTAssertFalse(JobStatus.completed.isActive)
    }

    /// Verifies that an unknown status is treated as inactive to avoid infinite polling.
    func testUnknownIsNotActive() {
        XCTAssertFalse(JobStatus.unknown("draining").isActive)
    }
}

// MARK: - JobConclusion.isFailure

final class JobConclusionIsFailureTests: XCTestCase {

    /// Verifies that failure, timedOut, startupFailure, and actionRequired are failures.
    func testFailureConclusions() {
        XCTAssertTrue(JobConclusion.failure.isFailure)
        XCTAssertTrue(JobConclusion.timedOut.isFailure)
        XCTAssertTrue(JobConclusion.startupFailure.isFailure)
        XCTAssertTrue(JobConclusion.actionRequired.isFailure)
    }

    /// Verifies that success and neutral are not failures.
    func testNonFailureConclusions() {
        XCTAssertFalse(JobConclusion.success.isFailure)
        XCTAssertFalse(JobConclusion.neutral.isFailure)
        XCTAssertFalse(JobConclusion.stale.isFailure)
    }

    /// Verifies that cancelled is not a failure — it is user-initiated, not a CI error.
    func testCancelledIsNotFailure() {
        XCTAssertFalse(JobConclusion.cancelled.isFailure)
    }

    /// Verifies that skipped is not a failure — it is a dependency-driven outcome, not a CI error.
    func testSkippedIsNotFailure() {
        XCTAssertFalse(JobConclusion.skipped.isFailure)
    }

    /// Verifies that an unknown conclusion is not treated as a failure.
    func testUnknownIsNotFailure() {
        XCTAssertFalse(JobConclusion.unknown("neutral_extended").isFailure)
    }
}

// MARK: - PollResultBuilder.buildGroupState (fix #1041)

final class PollResultBuilderGroupStateTests: XCTestCase {

    // MARK: Helpers

    private func makeGroup(
        id runID: Int,
        sha: String,
        groupStatus: GroupStatus = .completed,
        jobStatus: JobStatus? = nil,
        isDimmed: Bool = false
    ) -> WorkflowActionGroup {
        let runStatus: String
        switch groupStatus {
        case .inProgress: runStatus = "in_progress"
        case .queued:     runStatus = "queued"
        case .completed:  runStatus = "completed"
        }
        let resolvedJobStatus: JobStatus = jobStatus ?? JobStatus(rawString: runStatus)
        let jobConclusion: JobConclusion? = resolvedJobStatus == .completed ? .success : nil
        let job = ActiveJob(
            id: runID * 10,
            name: "job",
            status: resolvedJobStatus,
            conclusion: jobConclusion
        )
        return WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "commit message",
            headBranch: "main",
            repo: "owner/repo",
            runs: [WorkflowRunRef(id: runID, name: "CI", status: runStatus, conclusion: jobConclusion.map { $0.rawValue }, htmlUrl: nil)],
            jobs: [job],
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: resolvedJobStatus == .completed ? Date(timeIntervalSinceReferenceDate: 60) : nil,
            isDimmed: isDimmed
        )
    }

    // MARK: Tests

    /// Regression test for #1041: completed-only group must land in cache, not live display.
    func testCompletedOnlyGroupIsRoutedToCacheNotLive() {
        let completedGroup = makeGroup(id: 500, sha: "aabbcc", groupStatus: .completed)

        let result = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        XCTAssertTrue(
            result.display.filter { !$0.isDimmed }.isEmpty,
            "Completed group must not appear as a live (non-dimmed) row"
        )
        XCTAssertFalse(
            result.newGroupCache.isEmpty,
            "Completed group must be stored in the group cache"
        )
    }

    /// Verifies that an in-progress group appears as a live (non-dimmed) display row.
    func testInProgressGroupAppearsLiveInDisplay() {
        let liveGroup = makeGroup(id: 600, sha: "ddeeff", groupStatus: .inProgress, jobStatus: .inProgress)

        let result = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [liveGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        XCTAssertTrue(
            result.display.contains(where: { !$0.isDimmed }),
            "In-progress group must appear as a live (non-dimmed) row"
        )
    }

    /// fireFailureHook must fire exactly once for a newly-completed group.
    func testFireFailureHookCalledOnceForNewCompletedGroup() {
        let completedGroup = makeGroup(id: 700, sha: "112233", groupStatus: .completed)
        var hookCallCount = 0

        _ = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in hookCallCount += 1 },
            enrichJobs: { $0 }
        )

        XCTAssertEqual(hookCallCount, 1, "fireFailureHook must fire exactly once for a new completed group")
    }

    /// fireFailureHook must NOT re-fire when the group ID is already in snapSeenGroupIDs,
    /// even if it has been evicted from snapGroupCache by trimGroupCache.
    func testFireFailureHookNotCalledWhenGroupAlreadySeenEvenIfEvictedFromCache() {
        let completedGroup = makeGroup(id: 800, sha: "445566", groupStatus: .completed, isDimmed: true)
        var hookCallCount = 0

        _ = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],                              // evicted from display cache
            snapSeenGroupIDs: [completedGroup.id],           // but present in seen-IDs set
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in hookCallCount += 1 },
            enrichJobs: { $0 }
        )

        XCTAssertEqual(hookCallCount, 0,
            "fireFailureHook must not re-fire for a group already in seenGroupIDs, even after cache eviction")
    }

    /// Stale-row self-heal: group that was live in snapPrevGroups comes back completed → must land in cache.
    func testPreviouslyLiveGroupSelfHealsAfterCompletion() {
        let sha = "cafe01"
        let liveGroup      = makeGroup(id: 901, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
        let completedGroup = makeGroup(id: 901, sha: sha, groupStatus: .completed)

        let result = PollResultBuilder.buildGroupState(
            snapPrevGroups: [liveGroup.id: liveGroup],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        XCTAssertTrue(
            result.display.filter { !$0.isDimmed }.isEmpty,
            "Previously-live group must not remain as a live row after completing"
        )
        XCTAssertNotNil(
            result.newGroupCache[completedGroup.id],
            "Self-healed group must appear in the group cache"
        )
    }

    /// A mixed-SHA group (one in_progress run + one completed run) must produce exactly
    /// one live display entry and zero cache entries while still running.
    func testShaWithBothLiveAndCompletedRunsProducesOneDisplayEntry() {
        let sha = "beef02"
        let mixedGroup = WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "mixed commit",
            headBranch: "main",
            repo: "owner/repo",
            runs: [
                WorkflowRunRef(id: 902, name: "Lint",   status: "in_progress", conclusion: nil,       htmlUrl: nil),
                WorkflowRunRef(id: 903, name: "Deploy", status: "completed",   conclusion: "success", htmlUrl: nil),
            ],
            jobs: [
                ActiveJob(id: 9020, name: "lint-job",   status: JobStatus.inProgress),
                ActiveJob(id: 9030, name: "deploy-job", status: JobStatus.completed, conclusion: JobConclusion.success),
            ],
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: nil,
            isDimmed: false
        )

        let result = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [mixedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        let displayForSha = result.display.filter { $0.headSha == sha }
        let cacheForSha   = result.newGroupCache.values.filter { $0.headSha == sha }
        XCTAssertEqual(displayForSha.count, 1, "Mixed-run group must appear exactly once in display")
        XCTAssertEqual(cacheForSha.count,   0, "Mixed-run group must not be duplicated in cache while still live")
    }

    /// An ID evicted from seenGroupIDs by trimSeenGroupIDs will re-trigger the failure
    /// hook when it resurfaces in the feed on the next poll.
    ///
    /// This is a known limitation of the in-memory approximate eviction strategy.
    /// This test locks in that behaviour so any future change (e.g. switching to a
    /// persisted seen-set) is intentional and visible in the diff.
    func testEvictedGroupIDRefiresHookOnNextPoll() {
        let completedGroup = makeGroup(id: 1001, sha: "dead01", groupStatus: .completed)
        var hookCallCount = 0

        _ = PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],         // evicted — ID is gone
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in hookCallCount += 1 },
            enrichJobs: { $0 }
        )

        XCTAssertEqual(hookCallCount, 1,
            "A group whose ID was evicted from seenGroupIDs must re-fire the hook — known limitation")
    }

    /// A group present in both the fetched completed list (doneGroups) and snapPrevGroups
    /// (was live last poll) must fire the failure hook exactly once.
    ///
    /// The ordering invariant: doneGroups populates newSeenGroupIDs BEFORE
    /// freezeVanishedGroups runs, so when freezeVanishedGroups encounters the same
    /// group ID it finds it already in seenGroupIDs and skips the second fire.
    func testDoneGroupsSeenBeforeFreezeVanishedGroupsPreventsDoubleFire() {
        let sha = "ff0011"
        let liveVersion      = makeGroup(id: 1002, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
        let completedVersion = makeGroup(id: 1002, sha: sha, groupStatus: .completed)
        var hookCallCount = 0

        _ = PollResultBuilder.buildGroupState(
            snapPrevGroups: [liveVersion.id: liveVersion],  // was live last poll
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [completedVersion] },       // now returned as completed
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in hookCallCount += 1 },
            enrichJobs: { $0 }
        )

        XCTAssertEqual(hookCallCount, 1,
            "Group in both doneGroups and snapPrevGroups must fire the hook exactly once")
    }
}
