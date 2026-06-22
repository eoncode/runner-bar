// WorkflowActionGroupFetcherTests.swift
// RunnerBarCoreTests

import Foundation
import Testing
@testable import RunnerBarCore
import os

// MARK: - StubTransport

/// Minimal `GitHubTransportProtocol` stub for `WorkflowActionGroupFetcher` tests.
///
/// Responses are registered as an ordered array of `(prefix, Data)` pairs — the
/// *longest matching prefix* wins. When two registered prefixes have the same
/// length, the winning one is undefined because the input dictionary's iteration
/// order is unspecified. Test authors should ensure registered prefixes have
/// distinct lengths or non-overlapping URL paths to avoid ambiguity.
///
/// The responses array is immutable (set once at `init`), so `StubTransport` is
/// implicitly `Sendable`. The call counter uses `OSAllocatedUnfairLock` for
/// thread-safe concurrent access, following the project's established pattern
/// (see `ProcessRunner.swift`).
struct StubTransport: GitHubTransportProtocol {
    /// Ordered prefix → data pairs. Longest-prefix match wins.
    private let responses: [(prefix: String, data: Data)]

    /// Thread-safe call counter.
    private let _callCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// The number of times `apiAsync` has been called. Thread-safe.
    var callCount: Int { _callCount.withLock { $0 } }

    /// Creates a stub with the given endpoint-prefix → Data map.
    init(responses: [String: Data] = [:]) {
        // Sort longest prefix first so `apiAsync` picks the most specific match.
        // Same-length prefix ordering is undefined (input is a Dictionary).
        self.responses = responses.map { (prefix: $0.key, data: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
    }

    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        _callCount.withLock { $0 += 1 }
        return responses.first(where: { endpoint.hasPrefix($0.prefix) })?.data
    }

    func apiPaginated(_: String, timeout: TimeInterval) async -> Data? { nil }
    func raw(_: String, timeout: TimeInterval) async -> Data? { nil }
    func post(_: String, body: Data?, timeout: TimeInterval) async -> Data? { nil }
    func put(_: String, body: Data, timeout: TimeInterval) async -> Data? { nil }
    func delete(_: String, timeout: TimeInterval) async -> Bool { false }
    func cancelRun(runID: Int, scope: String) async -> Bool { false }
    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? { nil }
    func fetchRegistrationToken(scope: String) async -> String? { nil }
    func fetchRemovalToken(scope: String) async -> String? { nil }
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool { false }
}

// MARK: - JSON fixture helpers

private func runsEnvelope(_ runs: [[String: Any]]) -> Data {
    let envelope: [String: Any] = ["workflow_runs": runs]
    return try! JSONSerialization.data(withJSONObject: envelope)
}

private func jobsEnvelope(_ jobs: [[String: Any]]) -> Data {
    let envelope: [String: Any] = ["jobs": jobs]
    return try! JSONSerialization.data(withJSONObject: envelope)
}

private func minimalRun(id: Int, sha: String, status: String = "completed",
                        conclusion: String? = "success",
                        name: String = "CI") -> [String: Any] {
    var d: [String: Any] = ["id": id, "head_sha": sha, "status": status, "name": name]
    if let conclusion { d["conclusion"] = conclusion }
    return d
}

private func minimalJob(id: Int, name: String = "build",
                        status: String = "completed",
                        conclusion: String? = "success") -> [String: Any] {
    var d: [String: Any] = ["id": id, "name": name, "status": status]
    if let conclusion { d["conclusion"] = conclusion }
    return d
}

// MARK: - WorkflowActionGroupFetcherTests

@Suite("WorkflowActionGroupFetcher")
struct WorkflowActionGroupFetcherTests {
    // MARK: - Org scope guard

    @Test func fetchActionGroups_orgScope_returnsEmpty() async {
        let s = StubTransport()
        let f = WorkflowActionGroupFetcher(transport: s)
        let r = await f.fetch(for: "myorg")
        #expect(r.isEmpty)
        #expect(s.callCount == 0)
    }

    // MARK: - Empty API responses

    @Test func fetchActionGroups_allEndpointsEmpty_returnsEmpty() async {
        let e = runsEnvelope([])
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": e,
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": e,
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        #expect(await f.fetch(for: "owner/repo").isEmpty)
    }

    @Test func fetchActionGroups_nilResponses_returnsEmpty() async {
        let f = WorkflowActionGroupFetcher(transport: StubTransport())
        #expect(await f.fetch(for: "owner/repo").isEmpty)
    }

    // MARK: - Grouping by head_sha

    @Test func fetchActionGroups_twoRunsSameSha_producesOneGroup() async {
        let sha = "abc1234567890"
        let runs = [
            minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil, name: "build"),
            minimalRun(id: 2, sha: sha, status: "in_progress", conclusion: nil, name: "test"),
        ]
        let j = jobsEnvelope([minimalJob(id: 101), minimalJob(id: 102)])
        let e = runsEnvelope([])
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope(runs),
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": e,
            "repos/owner/repo/actions/runs/1/jobs": j,
            "repos/owner/repo/actions/runs/2/jobs": j,
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo")
        #expect(r.count == 1)
        #expect(r.first?.headSha == sha)
        #expect(r.first?.runs.count == 2)
        // Both runs return the same two jobs (101, 102); verify dedup produces exactly 2, not 4.
        #expect(r.first?.jobs.count == 2)
    }

    @Test func fetchActionGroups_twoRunsDifferentSha_producesTwoGroups() async {
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: "aaa111", status: "in_progress", conclusion: nil),
                minimalRun(id: 2, sha: "bbb222", status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": runsEnvelope([]),
            "repos/owner/repo/actions/runs?status=completed": runsEnvelope([]),
            "repos/owner/repo/actions/runs/1/jobs": jobsEnvelope([]),
            "repos/owner/repo/actions/runs/2/jobs": jobsEnvelope([]),
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo")
        #expect(r.count == 2)
        #expect(Set(r.map { $0.headSha }) == ["aaa111", "bbb222"])
    }

    // MARK: - Sort order

    @Test func fetchActionGroups_mixedStatuses_inProgressSortsFirst() async {
        let j = jobsEnvelope([])
        let e = runsEnvelope([])
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: "aaainprogress", status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": runsEnvelope([
                minimalRun(id: 2, sha: "bbbcompleted", status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs/1/jobs": j,
            "repos/owner/repo/actions/runs/2/jobs": j,
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo")
        #expect(r.count == 2)
        #expect(r.first?.headSha == "aaainprogress")
        #expect(r.last?.headSha == "bbbcompleted")
    }

    // MARK: - Cache hit

    @Test func fetchActionGroups_concludedCacheEntry_jobsNotRefetched() async {
        let sha = "cachedsha"
        let cached = WorkflowActionGroup(
            headSha: sha,
            label: sha,
            title: "Cached commit",
            headBranch: nil,
            repo: "owner/repo",
            runs: [],
            jobs: [ActiveJob(
                id: 999, name: "cached-build", htmlUrl: nil,
                status: .completed, conclusion: .success, isDimmed: false,
                runnerName: nil, scope: "owner/repo",
                startedAt: nil, completedAt: Date(), steps: []
            )],
            firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil
        )
        let e = runsEnvelope([])
        // No /jobs endpoints registered — fetcher must not call them.
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": e,
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo", cache: [sha: cached])
        #expect(r.count == 1)
        #expect(r.first?.jobs.first?.id == 999)
        #expect(t.callCount == 3)
    }
@Test func fetchActionGroups_concludedCacheWithInProgressStep_refetchesJobs() async {
        // A cached entry where a job is concluded but a step is still in-progress
        // must NOT serve from cache — the stale-step guard re-fetches via API.
        let sha = "staledash"
        let cached = WorkflowActionGroup(
            headSha: sha,
            label: sha,
            title: "Stale step commit",
            headBranch: nil,
            repo: "owner/repo",
            runs: [],
            jobs: [ActiveJob(
                id: 888, name: "stale-build", htmlUrl: nil,
                status: .completed, conclusion: .success, isDimmed: false,
                runnerName: nil, scope: "owner/repo",
                startedAt: nil, completedAt: Date(),
                steps: [JobStep(id: 1, name: "lint", status: .inProgress)]
            )],
            firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil
        )
        let e = runsEnvelope([])
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": e,
            "repos/owner/repo/actions/runs/1/jobs": jobsEnvelope([
                minimalJob(id: 888, status: "completed", conclusion: "success"),
            ]),
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo", cache: [sha: cached])
        #expect(r.count == 1)
        // 3 status calls + 1 jobs-list call = 4 (not 3 — cache was bypassed)
        #expect(t.callCount == 4)
    }

    // MARK: - Refresh cap
    // MARK: - Refresh cap

    @Test func fetchActionGroups_inProgressJobsCapped_atMaxRefreshConcurrency() async {
        // When a single run has 4 in-progress jobs but maxRefreshConcurrency is 3,
        // only 3 individual /actions/jobs/{id} refresh calls are dispatched.
        // The 4th job silently uses stale data — verified by the call count not reaching 8.
        let runID = 1
        let sha = "capcap"
        let inProgressJobs = (1 ... 4).map { i in
            minimalJob(id: 100 + i, status: "in_progress", conclusion: nil)
        }
        let e = runsEnvelope([])
        var responses: [String: Data] = [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: runID, sha: sha, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": e,
            "repos/owner/repo/actions/runs?status=completed": e,
            "repos/owner/repo/actions/runs/\(runID)/jobs": jobsEnvelope(inProgressJobs),
        ]
        // Register individual job endpoints for the first 3 jobs only.
        // Job 104 is deliberately unregistered — if the cap fails, the fetcher
        // will call it and get nil; the callCount assertion detects the difference.
        for i in 1 ... 3 {
            let job = minimalJob(id: 100 + i, status: "in_progress", conclusion: nil)
            responses["repos/owner/repo/actions/jobs/\(100 + i)"] =
                (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
        }
        let t = StubTransport(responses: responses)
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo")
        #expect(r.count == 1)
        #expect(r.first?.jobs.count == 4)
        // 3 status calls + 1 jobs-list call + 3 refresh calls = 7 (not 8)
        #expect(t.callCount == 7)
    }

    // MARK: - Repo label

    @Test func fetchActionGroups_singleRun_groupHasCorrectRepoScope() async {
        let t = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: "scopecheck", status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": runsEnvelope([]),
            "repos/owner/repo/actions/runs?status=completed": runsEnvelope([]),
            "repos/owner/repo/actions/runs/1/jobs": jobsEnvelope([]),
        ])
        let f = WorkflowActionGroupFetcher(transport: t)
        let r = await f.fetch(for: "owner/repo")
        #expect(r.first?.repo == "owner/repo")
    }
}
