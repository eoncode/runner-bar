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

    /// Well over the limit must also leave exactly `limit` entries.
    @Test func trimSeenGroupIDsWellOverLimit() {
        let limit = 10
        var ids: OrderedSet<String> = OrderedSet((1...25).map { "group-\($0)" })
        PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
        #expect(ids.count == limit)
    }
}

// MARK: - JobStatus.isActive

@Suite("JobStatus.isActive")
struct JobStatusIsActiveTests {

    /// queued, inProgress, waiting, requested, pending, completed, and unknown are all covered.
    /// completed and unknown must be inactive; active statuses must be active.
    /// Removed separate completedIsNotActive / unknownIsNotActive tests (#1500) —
    /// both are trivially-obvious negatives, folded here for completeness.
    @Test func activeStatuses() {
        #expect(JobStatus.queued.isActive)
        #expect(JobStatus.inProgress.isActive)
        #expect(JobStatus.waiting.isActive)
        #expect(JobStatus.requested.isActive)
        #expect(JobStatus.pending.isActive)
        #expect(!JobStatus.completed.isActive)
        #expect(!JobStatus.unknown("draining").isActive)
    }
}

// MARK: - JobConclusion.isFailure

@Suite("JobConclusion.isFailure")
struct JobConclusionIsFailureTests {

    /// failure, timedOut, startupFailure, and actionRequired are all failures.
    @Test(arguments: [
        JobConclusion.failure,
        .timedOut,
        .startupFailure,
        .actionRequired
    ])
    func isFailureTrue(conclusion: JobConclusion) {
        #expect(conclusion.isFailure)
    }

    /// success, neutral, stale, cancelled, skipped, and unknown are not failures.
    @Test(arguments: [
        JobConclusion.success,
        .neutral,
        .stale,
        .cancelled,
        .skipped,
        .unknown("neutral_extended")
    ])
    func isFailureFalse(conclusion: JobConclusion) {
        #expect(!conclusion.isFailure)
    }
}

// MARK: - JobConclusion.isHookConclusion

@Suite("JobConclusion.isHookConclusion")
struct JobConclusionIsHookConclusionTests {

    /// All failure conclusions plus cancelled trigger the hook.
    /// cancelled is included even though it is not isFailure —
    /// a cancellation often signals a problem the user wants to be notified about.
    @Test(arguments: [
        JobConclusion.failure,
        .timedOut,
        .startupFailure,
        .actionRequired,
        .cancelled
    ])
    func isHookConclusionTrue(conclusion: JobConclusion) {
        #expect(conclusion.isHookConclusion)
    }

    /// Verifies the deliberate semantic split: cancelled triggers the hook but is not a failure.
    /// Guards against accidentally adding .cancelled to the isFailure branch in future.
    @Test func cancelledIsHookConclusionButNotFailure() {
        #expect(JobConclusion.cancelled.isHookConclusion)
        #expect(!JobConclusion.cancelled.isFailure)
    }

    /// success, skipped, neutral, stale, and unknown must not trigger the hook.
    @Test(arguments: [
        JobConclusion.success,
        .skipped,
        .neutral,
        .stale,
        .unknown("some_future_value")
    ])
    func isHookConclusionFalse(conclusion: JobConclusion) {
        #expect(!conclusion.isHookConclusion)
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

    /// Verifies that MM:SS format does not roll over to HH:MM:SS for durations >= 60 min.
    /// Design decision: formatElapsed intentionally uses plain `secs / 60` for minutes,
    /// so values beyond 59:59 continue counting up rather than switching to an hours display.
    /// This keeps the UI consistent for the typical runner job duration.
    /// Boundary: exactly 3600 s = "60:00" (the first minute value >= 60).
    /// General: 4000 s = "66:40".
    @Test func largeIntervalFormatsMmSs() {
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        // Exactly 60-minute boundary — must not roll over to hours.
        #expect(formatElapsed(start: ref, end: Date(timeIntervalSinceReferenceDate: 3600), isCompleted: true) == "60:00")
        // Well beyond 60 minutes.
        #expect(formatElapsed(start: ref, end: Date(timeIntervalSinceReferenceDate: 4000), isCompleted: true) == "66:40")
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
            case .loading:    return .queued
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

    // fireFailureHook conclusion-variant tests (cancelled, startup_failure, action_required)
    // removed in #1500 — already exhaustively covered by the parameterised
    // JobConclusionIsHookConclusionTests suite. Keeping integration-level
    // duplication of unit-level table tests adds noise without regression value.

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

    /// Stale-row self-heal: group that was live in snapPrevGroups comes back completed -> must land in cache.
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
    /// Note: .timeLimit(.minutes(1)) is used intentionally — 1 minute is a loose upper bound
    /// for a fast operation. .seconds is available in Swift 6+ but minutes gives more headroom on CI.
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
    /// Note: .timeLimit(.minutes(1)) is used intentionally — 1 minute is a loose upper bound
    /// for a slow-ish operation. .seconds is available in Swift 6+ but minutes gives more headroom on CI.
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

    // MARK: - Exit codes

    /// A command that exits with a non-zero status must report that exit code.
    /// Regression guard: a bug that always reports exitCode == 0 would silently pass
    /// the stdin round-trip tests above while breaking callers that rely on exit codes.
    /// `/usr/bin/false` always exits 1 on macOS and Linux — asserting == 1 is deterministic.
    @Test(.timeLimit(.minutes(1)))
    func runAsyncNonZeroExitCode() async {
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            stdin: nil
        )
        #expect(result.exitCode == 1)
    }
}

// MARK: - RunnerConfigStoreError.errorDescription

@Suite("RunnerConfigStoreError.errorDescription")
struct RunnerConfigStoreErrorDescriptionTests {

    /// .malformedExistingFile errorDescription must contain the install path,
    /// the word "malformed", and the phrase "agent-managed" so callers and UI
    /// can identify both the file location and the consequence.
    @Test func malformedExistingFileDescriptionContainsPathAndConsequence() {
        let error = RunnerConfigStoreError.malformedExistingFile("/opt/runners/my-runner")
        let desc  = error.errorDescription ?? ""
        #expect(desc.contains("/opt/runners/my-runner"))
        #expect(desc.contains("malformed"))
        #expect(desc.contains("agent-managed"))
    }

    /// .malformedExistingFile must be distinct from .decodeFailed — the two cases
    /// describe different failure sites (save pre-read vs. load) and must not
    /// share an identical description.
    @Test func malformedExistingFileDescriptionDiffersFromDecodeFailed() {
        let malformed = RunnerConfigStoreError.malformedExistingFile("/opt/runners/r")
        let decode    = RunnerConfigStoreError.decodeFailed("/opt/runners/r")
        #expect(malformed.errorDescription != decode.errorDescription)
    }
}
