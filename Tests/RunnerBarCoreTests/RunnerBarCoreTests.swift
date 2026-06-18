// RunnerBarCoreTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
import RunnerBarCore

/// Stable install path used across test fixtures to avoid repeating a hardcoded URI literal.
private let testRunnerInstallPath = "/tmp/runner" // NOSONAR — test-only fixture path

// MARK: - ActiveJob.elapsed

@Suite("ActiveJob.elapsed")
struct ActiveJobElapsedTests {

    /// A queued job (never started) returns "00:00" elapsed time.
    @Test func elapsedQueuedReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        #expect(job.elapsed == "00:00")
    }

    /// Elapsed time is formatted as "MM:SS" when start and end dates are provided for a completed job.
    @Test func elapsedCompletedWithTimes() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 125)
        let job = ActiveJob(
            id: 1, name: "J", status: "completed",
            conclusion: "success",
            startedAt: start,
            completedAt: end
        )
        #expect(job.elapsed == "02:05")
    }

    /// A completed job without timestamps returns "--:--" as elapsed time.
    @Test func elapsedCompletedMissingTimesReturnsDashes() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", conclusion: "success")
        #expect(job.elapsed == "--:--")
    }

    /// An in-progress job calculates elapsed time from startedAt to now, within a reasonable tolerance.
    @Test func elapsedInProgressUsesStartedAt() {
        let start = Date(timeIntervalSinceNow: -90)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", startedAt: start)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        #expect(total >= 89)
        #expect(total <= 95)
    }

    /// An in-progress job falls back to createdAt when startedAt is nil (still queued/assigning).
    @Test func elapsedInProgressFallsBackToCreatedAt() {
        let created = Date(timeIntervalSinceNow: -60)
        let job = ActiveJob(id: 1, name: "J", status: "in_progress", createdAt: created)
        let mins = Int(job.elapsed.prefix(2))!
        let secs = Int(job.elapsed.suffix(2))!
        let total = mins * 60 + secs
        #expect(total >= 59)
        #expect(total <= 65)
    }

    /// An in-progress job with neither startedAt nor createdAt returns "00:00".
    @Test func elapsedInProgressNeitherDateReturnsZero() {
        let job = ActiveJob(id: 1, name: "J", status: "in_progress")
        #expect(job.elapsed == "00:00")
    }
}

// MARK: - JobStep.elapsed

@Suite("JobStep.elapsed")
struct JobStepElapsedTests {

    /// A completed job step formats elapsed time as "MM:SS" given fixed start/end dates.
    @Test func elapsedFixedDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 185) // 3m 5s
        let step = JobStep(id: 1, name: "S", status: "completed",
                           startedAt: start, completedAt: end)
        #expect(step.elapsed == "03:05")
    }

    /// A step with nil start and end dates returns "00:00".
    @Test func elapsedNilDatesReturnsZero() {
        let step = JobStep(id: 1, name: "S", status: "in_progress")
        #expect(step.elapsed == "00:00")
    }

    /// Exactly one minute (60 seconds) is formatted as "01:00".
    @Test func elapsedExactlyOneMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 60)
        let step = JobStep(id: 1, name: "S", status: "completed",
                           startedAt: start, completedAt: end)
        #expect(step.elapsed == "01:00")
    }
}

// MARK: - ActiveJob.isLocalRunner

@Suite("ActiveJob.isLocalRunner")
struct ActiveJobIsLocalRunnerTests {

    /// isLocalRunner returns nil when a job has no runner name.
    @Test func isLocalRunnerNilWhenNoRunnerName() {
        let job = ActiveJob(id: 1, name: "J", status: "queued")
        #expect(job.isLocalRunner == nil)
    }

    /// A GitHub-hosted Ubuntu runner is not considered local.
    @Test func isLocalRunnerFalseForUbuntuHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "ubuntu-latest")
        #expect(job.isLocalRunner == false)
    }

    /// A GitHub-hosted macOS runner is not considered local.
    @Test func isLocalRunnerFalseForMacOSHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "macos-14")
        #expect(job.isLocalRunner == false)
    }

    /// A GitHub-hosted Windows runner is not considered local.
    @Test func isLocalRunnerFalseForWindowsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "windows-2022")
        #expect(job.isLocalRunner == false)
    }

    /// A buildjet-hosted runner is not considered local.
    @Test func isLocalRunnerFalseForBuildjetHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "buildjet-4vcpu-ubuntu-2204")
        #expect(job.isLocalRunner == false)
    }

    /// A depot-hosted runner is not considered local.
    @Test func isLocalRunnerFalseForDepotHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "depot-ubuntu-22.04")
        #expect(job.isLocalRunner == false)
    }

    /// A runner named "GitHub Actions 12" (hosted by GitHub) is not considered local.
    @Test func isLocalRunnerFalseForGitHubActionsHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "GitHub Actions 12")
        #expect(job.isLocalRunner == false)
    }

    /// An arbitrary self-hosted runner name is identified as local.
    @Test func isLocalRunnerTrueForSelfHosted() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "my-mac-mini")
        #expect(job.isLocalRunner == true)
    }

    /// A custom-named runner (e.g., "office-m2-runner") is identified as local.
    @Test func isLocalRunnerTrueForCustomName() {
        let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "office-m2-runner")
        #expect(job.isLocalRunner == true)
    }
}

// MARK: - RunnerModel.displayStatus

@Suite("RunnerModel.displayStatus")
struct RunnerModelDisplayStatusTests {

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
            installPath: testRunnerInstallPath,
            isRunning: isRunning,
            githubStatus: githubStatus,
            isBusy: isBusy,
            lifecycleWarning: lifecycleWarning
        )
    }

    /// A running runner displays "running" status.
    @Test func displayStatusRunning() {
        #expect(makeRunner(isRunning: true).displayStatus == "running")
    }

    /// A runner with isBusy = true displays "busy" status (dead-branch fix for #773).
    @Test func displayStatusBusy() {
        #expect(makeRunner(isRunning: true, isBusy: true).displayStatus == "busy")
    }

    /// A non-running runner with GitHub status .online displays "online".
    @Test func displayStatusOnline() {
        #expect(makeRunner(isRunning: false, githubStatus: .online).displayStatus == "online")
    }

    /// A non-running runner with GitHub status .offline displays "offline".
    @Test func displayStatusOffline() {
        #expect(makeRunner(isRunning: false, githubStatus: .offline).displayStatus == "offline")
    }

    /// A lifecycle warning overrides the running/busy status.
    @Test func displayStatusLifecycleWarningTakesPriority() {
        let runner = makeRunner(isRunning: true, lifecycleWarning: "update required")
        #expect(runner.displayStatus == "update required")
    }

    /// A non-running runner with GitHub status .busy displays "busy".
    @Test func displayStatusBusyGithubStatusWhenNotRunning() {
        #expect(makeRunner(isRunning: false, githubStatus: .busy).displayStatus == "busy")
    }

    /// A non-running runner with an unknown GitHub status defaults to "offline".
    @Test func displayStatusDefaultsToOfflineForUnknownStatus() {
        #expect(makeRunner(isRunning: false, githubStatus: .unknown("draining")).displayStatus == "offline")
    }
}

// MARK: - RunnerModel.statusColor

@Suite("RunnerModel.statusColor")
struct RunnerModelStatusColorTests {

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
            installPath: testRunnerInstallPath,
            isRunning: isRunning,
            githubStatus: githubStatus,
            isBusy: isBusy,
            lifecycleWarning: lifecycleWarning
        )
    }

    /// A running, non-busy runner gets the .running dot colour.
    @Test func statusColorRunning() {
        #expect(makeRunner(isRunning: true).statusColor == .running)
    }

    /// A running and busy runner gets the .busy dot colour.
    @Test func statusColorBusy() {
        #expect(makeRunner(isRunning: true, isBusy: true).statusColor == .busy)
    }

    /// A non-running runner that GitHub reports as online gets the .idle dot colour.
    @Test func statusColorGithubOnlineIsIdle() {
        #expect(makeRunner(isRunning: false, githubStatus: .online).statusColor == .idle)
    }

    /// A non-running runner with an offline GitHub status gets the .offline dot colour.
    @Test func statusColorOffline() {
        #expect(makeRunner(isRunning: false, githubStatus: .offline).statusColor == .offline)
    }

    /// A lifecycle warning maps to the .offline dot colour.
    @Test func statusColorLifecycleWarning() {
        #expect(makeRunner(isRunning: true, lifecycleWarning: "restart failed").statusColor == .offline)
    }

    /// An unknown GitHub status (not running locally) maps to .offline.
    @Test func statusColorUnknownGithubStatus() {
        #expect(makeRunner(isRunning: false, githubStatus: .unknown("draining")).statusColor == .offline)
    }
}

// MARK: - Runner.displayStatus

@Suite("Runner.displayStatus")
struct RunnerDisplayStatusTests {

    private func makeRunner(status: RunnerStatus, busy: Bool = false, metrics: RunnerMetrics? = nil) -> Runner {
        Runner(id: 1, name: "r", status: status, busy: busy, metrics: metrics)
    }

    /// An offline runner returns "offline".
    @Test func offlineReturnsOffline() {
        #expect(makeRunner(status: .offline).displayStatus == "offline")
    }

    /// An unknown status returns "offline" (not idle/active).
    @Test func unknownReturnsOffline() {
        #expect(makeRunner(status: .unknown("draining")).displayStatus == "offline")
    }

    /// An online, non-busy runner with no metrics returns the idle placeholder.
    @Test func onlineIdleNoMetrics() {
        #expect(makeRunner(status: .online, busy: false).displayStatus == "idle (CPU: \u{2014} MEM: \u{2014})")
    }

    /// An online, busy runner with metrics returns the active format.
    @Test func onlineBusyWithMetrics() {
        let m = RunnerMetrics(cpu: 45.0, mem: 12.3)
        #expect(makeRunner(status: .online, busy: true, metrics: m).displayStatus == "active (CPU: 45.0% MEM: 12.3%)")
    }

    /// A busy status (from API) is treated same as online for display.
    @Test func busyStatusShowsActiveWithMetrics() {
        let m = RunnerMetrics(cpu: 80.0, mem: 50.0)
        #expect(makeRunner(status: .busy, busy: true, metrics: m).displayStatus == "active (CPU: 80.0% MEM: 50.0%)")
    }
}

// MARK: - RunnerMetrics

@Suite("RunnerMetrics")
struct RunnerMetricsTests {

    /// Two RunnerMetrics with identical CPU and memory values are considered equal.
    @Test func equatableSameValues() {
        let a = RunnerMetrics(cpu: 12.5, mem: 3.0)
        let b = RunnerMetrics(cpu: 12.5, mem: 3.0)
        #expect(a == b)
    }

    /// Two RunnerMetrics with different CPU values are considered not equal.
    @Test func equatableDifferentCPU() {
        let a = RunnerMetrics(cpu: 10.0, mem: 3.0)
        let b = RunnerMetrics(cpu: 20.0, mem: 3.0)
        #expect(a != b)
    }

    /// Two RunnerMetrics with different memory values are considered not equal.
    @Test func equatableDifferentMem() {
        let a = RunnerMetrics(cpu: 10.0, mem: 1.0)
        let b = RunnerMetrics(cpu: 10.0, mem: 2.0)
        #expect(a != b)
    }
}

// MARK: - AggregateStatus

@Suite("AggregateStatus")
struct AggregateStatusTests {

    /// allOnline status returns the green circle dot character.
    @Test func dotAllOnline() {
        #expect(AggregateStatus.allOnline.dot == "\u{1F7E2}")
    }

    /// someOffline status returns the yellow circle dot character.
    @Test func dotSomeOffline() {
        #expect(AggregateStatus.someOffline.dot == "\u{1F7E1}")
    }

    /// allOffline status returns the black circle dot character.
    @Test func dotAllOffline() {
        #expect(AggregateStatus.allOffline.dot == "\u{26AB}")
    }

    /// allOnline status maps to the SF Symbol "circle.fill".
    @Test func symbolNameAllOnline() {
        #expect(AggregateStatus.allOnline.symbolName == "circle.fill")
    }

    /// someOffline status maps to the SF Symbol "circle.lefthalf.filled".
    @Test func symbolNameSomeOffline() {
        #expect(AggregateStatus.someOffline.symbolName == "circle.lefthalf.filled")
    }

    /// allOffline status maps to the SF Symbol "circle".
    @Test func symbolNameAllOffline() {
        #expect(AggregateStatus.allOffline.symbolName == "circle")
    }
}

// MARK: - PollResultBuilder (pure logic)

@Suite("PollResultBuilder")
struct PollResultBuilderTests {

    // MARK: trimJobCache

    /// trimJobCache removes the oldest completed job entries when the cache exceeds the given limit.
    @Test func trimJobCacheRemovesOldestWhenOverLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 100)),
            2: ActiveJob(id: 2, name: "B", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 200)),
            3: ActiveJob(id: 3, name: "C", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 300)),
            4: ActiveJob(id: 4, name: "D", status: "completed", completedAt: Date(timeIntervalSinceReferenceDate: 400)),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        #expect(cache.count == 3)
        #expect(cache[1] == nil, "Oldest entry should be evicted")
    }

    /// trimJobCache does nothing when the cache is already under the limit.
    @Test func trimJobCacheNoopWhenUnderLimit() {
        var cache: [Int: ActiveJob] = [
            1: ActiveJob(id: 1, name: "A", status: "completed"),
            2: ActiveJob(id: 2, name: "B", status: "completed"),
        ]
        PollResultBuilder.trimJobCache(&cache, limit: 3)
        #expect(cache.count == 2)
    }

    // MARK: buildJobDisplay

    /// buildJobDisplay places live (in-progress) jobs before cached (completed) jobs in the display list.
    @Test func buildJobDisplayLiveJobsFirst() {
        let live: [ActiveJob] = [
            ActiveJob(id: 10, name: "Live", status: "in_progress")
        ]
        let cache: [Int: ActiveJob] = [
            20: ActiveJob(id: 20, name: "Done", status: "completed", conclusion: "success")
        ]
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: cache)
        #expect(display.first?.id == 10)
        #expect(display.contains(where: { $0.id == 20 }))
    }

    /// buildJobDisplay returns an empty array when both live and cache are empty.
    @Test func buildJobDisplayEmptyLiveAndCacheIsEmpty() {
        let display = PollResultBuilder.buildJobDisplay(live: [], cache: [:])
        #expect(display.isEmpty)
    }

    /// Live jobs beyond jobCacheLimit (3) are NOT silently dropped (bug fix for #776).
    @Test func buildJobDisplayDoesNotCapLiveJobsAtCacheLimit() {
        let live: [ActiveJob] = (1...5).map {
            ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
        }
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: [:])
        #expect(display.count == 5, "jobCacheLimit must not truncate live jobs")
    }

    /// The total display list is capped at jobDisplayLimit (8).
    @Test func buildJobDisplayCapsAtJobDisplayLimit() {
        let live: [ActiveJob] = (1...8).map {
            ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
        }
        let cached: [Int: ActiveJob] = Dictionary(uniqueKeysWithValues: (100...106).map {
            ($0, ActiveJob(id: $0, name: "Done \($0)", status: "completed",
                           conclusion: "success",
                           completedAt: Date(timeIntervalSinceReferenceDate: Double($0))))
        })
        let display = PollResultBuilder.buildJobDisplay(live: live, cache: cached)
        #expect(display.count <= PollResultBuilder.jobDisplayLimit)
    }

    // MARK: applyVanishedJobs

    /// A job present in the previous snapshot but missing from live results is moved to the cache
    /// with "completed" status, dimmed, and .cancelled conclusion.
    @Test func applyVanishedJobsMovesVanishedJobToCache() {
        let vanished = ActiveJob(id: 55, name: "Vanished", status: "in_progress")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [55: vanished],
            liveIDs: [],
            now: Date(),
            into: &cache
        )
        #expect(cache[55] != nil)
        #expect(cache[55]?.status == "completed")
        #expect(cache[55]?.isDimmed == true)
        #expect(cache[55]?.conclusion == "neutral", "Missing conclusion defaults to neutral (.cancelled has isHookConclusion side-effects)")
    }

    /// An existing cached entry for a vanished job is not overwritten by the vanish logic.
    @Test func applyVanishedJobsDoesNotOverwriteExistingCacheEntry() {
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
        #expect(cache[55]?.conclusion == "failure", "Existing cache entry must not be overwritten")
    }

    /// Jobs still present in the live list are NOT moved to the cache.
    @Test func applyVanishedJobsIgnoresStillLiveJobs() {
        let job = ActiveJob(id: 77, name: "StillLive", status: "in_progress")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [77: job],
            liveIDs: [77],
            now: Date(),
            into: &cache
        )
        #expect(cache[77] == nil)
    }

    /// A vanished job with an existing conclusion (e.g., "failure") preserves that conclusion in the cache.
    @Test func applyVanishedJobsPreservesExistingConclusion() {
        let vanished = ActiveJob(id: 88, name: "Done", status: "completed",
                                 conclusion: "failure")
        var cache: [Int: ActiveJob] = [:]
        PollResultBuilder.applyVanishedJobs(
            snapPrev: [88: vanished],
            liveIDs: [],
            now: Date(),
            into: &cache
        )
        #expect(cache[88]?.conclusion == "failure")
    }

    // MARK: buildJobState

    /// A live job from fetchJobs appears in the display list of the returned job state.
    @Test func buildJobStateLiveJobAppearsInDisplay() async {
        let liveJob = ActiveJob(id: 99, name: "CI", status: "in_progress")
        let result = await PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [liveJob] },
            backfill: { _ in }
        )
        #expect(result.display.contains(where: { $0.id == 99 }))
    }

    /// A completed job from fetchJobs is moved to the cache and marked as dimmed.
    @Test func buildJobStateCompletedJobMovesToCache() async {
        let doneJob = ActiveJob(id: 42, name: "Deploy", status: "completed", conclusion: "success")
        let result = await PollResultBuilder.buildJobState(
            snapPrev: [:],
            snapCache: [:],
            fetchJobs: { [doneJob] },
            backfill: { _ in }
        )
        #expect(result.newCache.keys.contains(42))
        #expect(result.newCache[42]?.isDimmed == true)
    }

    /// A job that was live in the previous poll but is absent from fetchJobs is moved to the cache as vanished.
    @Test func buildJobStateVanishedLiveJobAppearsInCache() async {
        let prev = ActiveJob(id: 11, name: "Old", status: "in_progress")
        let result = await PollResultBuilder.buildJobState(
            snapPrev: [11: prev],
            snapCache: [:],
            fetchJobs: { [] },
            backfill: { _ in }
        )
        #expect(result.newCache[11] != nil)
        #expect(result.newCache[11]?.status == "completed")
    }

    // MARK: trimSeenGroupIDs

    /// Set at exactly the limit must not be modified.
    @Test func trimSeenGroupIDsNoopAtLimit() {
        var ids: Set<String> = Set((1...10).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
        #expect(ids.count == 10)
    }

    /// One entry over the limit must leave exactly `limit` entries, not `limit/2`.
    /// Guards against the off-by-half bug where trimming would remove half the set
    /// instead of only the single excess entry.
    @Test func trimSeenGroupIDsTrimsToLimitNotHalf() {
        let limit = 10
        var ids: Set<String> = Set((1...(limit + 1)).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
        #expect(ids.count == limit)
    }

    /// Well over the limit must also leave exactly `limit` entries.
    @Test func trimSeenGroupIDsWellOverLimit() {
        let limit = 10
        var ids: Set<String> = Set((1...25).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
        #expect(ids.count == limit)
    }
}

// MARK: - JobStatus.isActive

@Suite("JobStatus.isActive")
struct JobStatusIsActiveTests {

    /// queued, inProgress, waiting, requested, and pending are all active.
    @Test func activeStatuses() {
        #expect(JobStatus.queued.isActive)
        #expect(JobStatus.inProgress.isActive)
        #expect(JobStatus.waiting.isActive)
        #expect(JobStatus.requested.isActive)
        #expect(JobStatus.pending.isActive)
    }

    /// completed is not active.
    @Test func completedIsNotActive() {
        #expect(!JobStatus.completed.isActive)
    }

    /// An unknown status is treated as inactive to avoid infinite polling.
    @Test func unknownIsNotActive() {
        #expect(!JobStatus.unknown("draining").isActive)
    }
}

// MARK: - JobConclusion.isFailure

@Suite("JobConclusion.isFailure")
struct JobConclusionIsFailureTests {

    /// failure, timedOut, startupFailure, and actionRequired are failures.
    @Test func failureConclusions() {
        #expect(JobConclusion.failure.isFailure)
        #expect(JobConclusion.timedOut.isFailure)
        #expect(JobConclusion.startupFailure.isFailure)
        #expect(JobConclusion.actionRequired.isFailure)
    }

    /// success and neutral are not failures.
    @Test func nonFailureConclusions() {
        #expect(!JobConclusion.success.isFailure)
        #expect(!JobConclusion.neutral.isFailure)
        #expect(!JobConclusion.stale.isFailure)
    }

    /// cancelled is not a failure — it is user-initiated, not a CI error.
    @Test func cancelledIsNotFailure() {
        #expect(!JobConclusion.cancelled.isFailure)
    }

    /// skipped is not a failure — it is a dependency-driven outcome, not a CI error.
    @Test func skippedIsNotFailure() {
        #expect(!JobConclusion.skipped.isFailure)
    }

    /// An unknown conclusion is not treated as a failure.
    @Test func unknownIsNotFailure() {
        #expect(!JobConclusion.unknown("neutral_extended").isFailure)
    }
}

// MARK: - JobConclusion.isHookConclusion

@Suite("JobConclusion.isHookConclusion")
struct JobConclusionIsHookConclusionTests {

    /// All isFailure conclusions are also isHookConclusion.
    @Test func allFailureConclusionsAreHookConclusions() {
        #expect(JobConclusion.failure.isHookConclusion)
        #expect(JobConclusion.timedOut.isHookConclusion)
        #expect(JobConclusion.startupFailure.isHookConclusion)
        #expect(JobConclusion.actionRequired.isHookConclusion)
    }

    /// cancelled is a hook conclusion even though it is not isFailure.
    /// A cancellation often signals a problem the user wants to be notified about.
    @Test func cancelledIsHookConclusionButNotFailure() {
        #expect(JobConclusion.cancelled.isHookConclusion)
        #expect(!JobConclusion.cancelled.isFailure)
    }

    /// success must not trigger the hook.
    @Test func successIsNotHookConclusion() {
        #expect(!JobConclusion.success.isHookConclusion)
    }

    /// skipped must not trigger the hook.
    @Test func skippedIsNotHookConclusion() {
        #expect(!JobConclusion.skipped.isHookConclusion)
    }

    /// neutral must not trigger the hook.
    @Test func neutralIsNotHookConclusion() {
        #expect(!JobConclusion.neutral.isHookConclusion)
    }

    /// stale must not trigger the hook.
    @Test func staleIsNotHookConclusion() {
        #expect(!JobConclusion.stale.isHookConclusion)
    }

    /// An unknown conclusion must not trigger the hook (conservative default).
    @Test func unknownIsNotHookConclusion() {
        #expect(!JobConclusion.unknown("some_future_value").isHookConclusion)
    }
}

// MARK: - formatElapsed

@Suite("formatElapsed")
struct FormatElapsedTests {

    /// nil start + isCompleted=false returns "00:00" (not yet started).
    @Test func nilStartNotCompletedReturnsZero() {
        #expect(formatElapsed(start: nil, end: nil, isCompleted: false) == "00:00")
    }

    /// nil start + isCompleted=true returns "--:--" (completed but timing data unavailable).
    @Test func nilStartCompletedReturnsDashes() {
        #expect(formatElapsed(start: nil, end: nil, isCompleted: true) == "--:--")
    }

    /// Valid start + nil end measures elapsed time up to now (still running).
    /// Asserts a window rather than an exact value to tolerate scheduling jitter.
    @Test func validStartNilEndMeasuresToNow() {
        let start = Date(timeIntervalSinceNow: -65)
        let result = formatElapsed(start: start, end: nil, isCompleted: false)
        let mins = Int(result.prefix(2))!
        let secs = Int(result.suffix(2))!
        let total = mins * 60 + secs
        #expect(total >= 64)
        #expect(total <= 70)
    }

    /// Valid start + valid end returns exact "MM:SS" for the given interval.
    @Test func validStartAndEndReturnsExactFormat() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 167) // 2m 47s
        #expect(formatElapsed(start: start, end: end, isCompleted: true) == "02:47")
    }

    /// A sub-second interval rounds down to "00:00".
    @Test func subSecondIntervalReturnsZero() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = Date(timeIntervalSinceReferenceDate: 0.9)
        #expect(formatElapsed(start: start, end: end, isCompleted: true) == "00:00")
    }

    /// end before start clamps to "00:00" rather than producing a negative string.
    @Test func endBeforeStartClampsToZero() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let end   = Date(timeIntervalSinceReferenceDate: 50)
        #expect(formatElapsed(start: start, end: end, isCompleted: true) == "00:00")
    }
}

// MARK: - PollResultBuilder.buildGroupState (fix #1041)

@Suite("PollResultBuilder.buildGroupState")
struct PollResultBuilderGroupStateTests {

    // MARK: Helpers

    private func makeGroup(
        id runID: Int,
        sha: String,
        groupStatus: GroupStatus = .completed,
        conclusion: String = "failure",
        jobStatus: JobStatus? = nil,
        isDimmed: Bool = false
    ) -> WorkflowActionGroup {
        let resolvedJobStatus: JobStatus = jobStatus ?? {
            switch groupStatus {
            case .inProgress: return .inProgress
            case .queued:     return .queued
            case .completed:  return .completed
            }
        }()
        let jobConclusion: JobConclusion? = resolvedJobStatus == .completed
            ? JobConclusion(rawString: conclusion)
            : nil
        let job = ActiveJob(
            id: runID * 10,
            name: "job",
            status: resolvedJobStatus,
            conclusion: jobConclusion
        )
        let runConclusion: JobConclusion? = resolvedJobStatus == .completed
            ? JobConclusion(rawString: conclusion)
            : nil
        return WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "commit message",
            headBranch: "main",
            repo: "owner/repo",
            runs: [WorkflowRunRef(id: runID, name: "CI", status: resolvedJobStatus, conclusion: runConclusion, htmlUrl: nil)],
            jobs: [job],
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: resolvedJobStatus == .completed ? Date(timeIntervalSinceReferenceDate: 60) : nil,
            isDimmed: isDimmed
        )
    }

    // MARK: Tests

    /// Regression test for #1041: completed-only group must land in cache, not live display.
    @Test func completedOnlyGroupIsRoutedToCacheNotLive() async {
        let completedGroup = makeGroup(id: 500, sha: "aabbcc", groupStatus: .completed, conclusion: "failure")

        let result = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        #expect(result.display.filter { !$0.isDimmed }.isEmpty, "Completed group must not appear as a live (non-dimmed) row")
        #expect(!result.newGroupCache.isEmpty)
    }

    /// An in-progress group appears as a live (non-dimmed) display row.
    @Test func inProgressGroupAppearsLiveInDisplay() async {
        let liveGroup = makeGroup(id: 600, sha: "ddeeff", groupStatus: .inProgress, jobStatus: .inProgress)

        let result = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [liveGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        #expect(result.display.contains(where: { !$0.isDimmed }))
    }

    /// fireFailureHook must fire exactly once for a newly-completed failed group.
    @Test func fireFailureHookCalledOnceForNewFailedGroup() async {
        let failedGroup = makeGroup(id: 700, sha: "112233", groupStatus: .completed, conclusion: "failure")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [failedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1, "fireFailureHook must fire exactly once for a new failed group")
    }

    /// fireFailureHook must NOT fire for a successfully completed group.
    @Test func fireFailureHookNotCalledForSuccessGroup() async {
        let successGroup = makeGroup(id: 750, sha: "aabbdd", groupStatus: .completed, conclusion: "success")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [successGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 0)
    }

    /// fireFailureHook fires for a cancelled group — cancellation is a hook-triggering conclusion.
    @Test func fireFailureHookFiredForCancelledGroup() async {
        let cancelledGroup = makeGroup(id: 760, sha: "aabbee", groupStatus: .completed, conclusion: "cancelled")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [cancelledGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1, "fireFailureHook must fire for a cancelled group")
    }

    /// fireFailureHook fires for a startup_failure group.
    @Test func fireFailureHookFiredForStartupFailureGroup() async {
        let group = makeGroup(id: 770, sha: "aaccff", groupStatus: .completed, conclusion: "startup_failure")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [group] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1, "fireFailureHook must fire for startup_failure")
    }

    /// fireFailureHook fires for an action_required group.
    @Test func fireFailureHookFiredForActionRequiredGroup() async {
        let group = makeGroup(id: 780, sha: "bbccdd", groupStatus: .completed, conclusion: "action_required")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [group] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1, "fireFailureHook must fire for action_required")
    }

    /// fireFailureHook must NOT re-fire when the group ID is already in snapSeenGroupIDs,
    /// even if it has been evicted from snapGroupCache by trimGroupCache.
    @Test func fireFailureHookNotCalledWhenGroupAlreadySeenEvenIfEvictedFromCache() async {
        let completedGroup = makeGroup(id: 800, sha: "445566", groupStatus: .completed, conclusion: "failure", isDimmed: true)
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [completedGroup.id],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 0)
    }

    /// Stale-row self-heal: group that was live in snapPrevGroups comes back completed → must land in cache.
    @Test func previouslyLiveGroupSelfHealsAfterCompletion() async {
        let sha = "cafe01"
        let liveGroup      = makeGroup(id: 901, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
        let completedGroup = makeGroup(id: 901, sha: sha, groupStatus: .completed, conclusion: "failure")

        let result = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [liveGroup.id: liveGroup],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        #expect(result.display.filter { !$0.isDimmed }.isEmpty)
        #expect(result.newGroupCache[completedGroup.id] != nil)
    }

    /// A mixed-SHA group (one in_progress run + one completed run) must produce exactly
    /// one live display entry and zero cache entries while still running.
    @Test func shaWithBothLiveAndCompletedRunsProducesOneDisplayEntry() async {
        let sha = "beef02"
        let mixedGroup = WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "mixed commit",
            headBranch: "main",
            repo: "owner/repo",
            runs: [
                WorkflowRunRef(id: 902, name: "Lint",   status: JobStatus.inProgress, conclusion: nil,                   htmlUrl: nil),
                WorkflowRunRef(id: 903, name: "Deploy", status: JobStatus.completed,  conclusion: JobConclusion.success, htmlUrl: nil),
            ],
            jobs: [
                ActiveJob(id: 9020, name: "lint-job",   status: JobStatus.inProgress),
                ActiveJob(id: 9030, name: "deploy-job", status: JobStatus.completed, conclusion: JobConclusion.success),
            ],
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: nil,
            isDimmed: false
        )

        let result = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [mixedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in },
            enrichJobs: { $0 }
        )

        let displayForSha = result.display.filter { $0.headSha == sha }
        let cacheForSha   = result.newGroupCache.values.filter { $0.headSha == sha }
        #expect(displayForSha.count == 1)
        #expect(cacheForSha.count == 0)
    }

    /// An ID evicted from seenGroupIDs by trimSeenGroupIDs will re-trigger the failure
    /// hook when it resurfaces in the feed on the next poll.
    /// Known limitation: seenGroupIDs is an in-memory approximate set; eviction is
    /// intentional to bound memory, and the occasional re-fire is an accepted trade-off.
    @Test func evictedGroupIDRefiresHookOnNextPoll() async {
        let failedGroup = makeGroup(id: 1001, sha: "dead01", groupStatus: .completed, conclusion: "failure")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [failedGroup] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1)
    }

    /// A group present in both the fetched completed list (doneGroups) and snapPrevGroups
    /// (was live last poll) must fire the failure hook exactly once.
    /// The ordering invariant — doneGroups are processed before freezeVanishedGroups —
    /// ensures the group is marked seen before the vanish path can re-fire the hook.
    @Test func doneGroupsSeenBeforeFreezeVanishedGroupsPreventsDoubleFire() async {
        let sha = "ff0011"
        let liveVersion      = makeGroup(id: 1002, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
        let completedVersion = makeGroup(id: 1002, sha: sha, groupStatus: .completed, conclusion: "failure")
        let counter = HookCounter()

        _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [liveVersion.id: liveVersion],
            snapGroupCache: [:],
            snapSeenGroupIDs: [],
            fetchGroups: { _ in [completedVersion] },
            scopeFromGroup: { $0.repo },
            fireFailureHook: { _, _ in await counter.increment() },
            enrichJobs: { $0 }
        )

        #expect(await counter.value == 1, "doneGroups must be marked seen before freezeVanishedGroups runs to prevent double-fire")
    }
}

// MARK: - ProcessRunner.runAsync stdin

@Suite("ProcessRunner.runAsync stdin")
struct ProcessRunnerRunAsyncStdinTests {

    /// runAsync correctly pipes stdin through to the child process for a small payload.
    /// Note: Swift Testing .timeLimit only accepts .minutes; .seconds is not available.
    /// 1 minute is the minimum granularity and is intentionally loose vs the original 5 s XCTest limit.
    @Test(.timeLimit(.minutes(1)))
    func runAsyncStdinSmallPayloadRoundtrip() async {
        let input = "hello stdin"
        let data = Data(input.utf8)
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: data
        )
        #expect(result.exitCode == 0)
        #expect(result.output == input)
    }

    /// runAsync does NOT deadlock with a large stdin payload (1 MB — above the ~64 KB kernel pipe buffer).
    /// Regression test for the pre-launch synchronous write bug in #1228.
    /// Note: Swift Testing .timeLimit only accepts .minutes; .seconds is not available.
    /// 1 minute is the minimum granularity and is intentionally loose vs the original 10 s XCTest limit.
    @Test(.timeLimit(.minutes(1)))
    func runAsyncStdinLargePayloadRoundtrip() async {
        let input = String(repeating: "x", count: 1_024 * 1_024) // 1 MB
        let data = Data(input.utf8)
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: data
        )
        #expect(result.exitCode == 0)
        #expect(result.output.count == input.count)
    }
}

// MARK: - HookCounter

/// Actor-isolated counter for tracking fireFailureHook call counts in async tests.
private actor HookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
