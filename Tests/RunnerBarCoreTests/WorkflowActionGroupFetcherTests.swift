// WorkflowActionGroupFetcherTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helper

private final class _Counter: @unchecked Sendable {
    var value = 0
}

// MARK: - StubTransport

struct StubTransport: GitHubTransportProtocol {
    private let responses: [(prefix: String, data: Data)]
    private let _callCount = _Counter()
    var callCount: Int { _callCount.value }

    init(responses: [String: Data] = [:]) {
        self.responses = responses.map { (prefix: $0.key, data: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
    }

    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        _callCount.value += 1
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
    return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
}

private func jobsEnvelope(_ jobs: [[String: Any]]) -> Data {
    let envelope: [String: Any] = ["jobs": jobs]
    return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
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

    @Test func fetchActionGroups_orgScope_returnsEmpty() async {
        let transport = StubTransport()
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "myorg")
        #expect(result.isEmpty)
    }

    @Test func fetchActionGroups_allEndpointsEmpty_returnsEmpty() async {
        let emptyEnvelope = runsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": emptyEnvelope,
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.isEmpty)
    }

    @Test func fetchActionGroups_nilResponses_returnsEmpty() async {
        let fetcher = WorkflowActionGroupFetcher(transport: StubTransport())
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.isEmpty)
    }

    @Test func fetchActionGroups_twoRunsSameSha_producesOneGroup() async {
        let sha = "abc1234567890"
        let runs = [
            minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil, name: "build"),
            minimalRun(id: 2, sha: sha, status: "in_progress", conclusion: nil, name: "test"),
        ]
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([minimalJob(id: 101), minimalJob(id: 102)])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope(runs),
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":             jobsData,
            "repos/owner/repo/actions/runs/2/jobs":             jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 1)
        #expect(result.first?.headSha == sha)
        #expect(result.first?.runs.count == 2)
    }

    @Test func fetchActionGroups_twoRunsDifferentSha_producesTwoGroups() async {
        let sha1 = "aaa111"
        let sha2 = "bbb222"
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha1, status: "in_progress", conclusion: nil),
                minimalRun(id: 2, sha: sha2, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued":      emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed":   emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":             jobsData,
            "repos/owner/repo/actions/runs/2/jobs":             jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 2)
    }

    @Test func fetchActionGroups_mixedStatuses_inProgressSortsFirst() async {
        let shaInProgress = "inprogress1"
        let shaCompleted  = "completed1"
        let emptyEnvelope = runsEnvelope([])
        let jobsData = jobsEnvelope([minimalJob(id: 1)])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: shaInProgress, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued": emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": runsEnvelope([
                minimalRun(id: 2, sha: shaCompleted, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs/1/jobs": jobsData,
            "repos/owner/repo/actions/runs/2/jobs": jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.count == 2)
        #expect(result.first?.headSha == shaInProgress)
        #expect(result.last?.headSha  == shaCompleted)
    }

    @Test func fetchActionGroups_concludedCacheEntry_jobsNotRefetched() async {
        let sha = "cachedsha"
        let cachedJob = ActiveJob(
            id: 999, name: "cached-build", htmlUrl: nil,
            status: .completed, conclusion: .success, isDimmed: false,
            runnerName: nil, scope: "owner/repo",
            startedAt: nil, completedAt: Date(), steps: []
        )
        let cachedGroup = WorkflowActionGroup(
            headSha: sha, label: sha, title: "Cached commit",
            headBranch: nil, repo: "owner/repo", runs: [], jobs: [cachedJob],
            firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil
        )
        let emptyEnvelope = runsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success"),
            ]),
            "repos/owner/repo/actions/runs?status=queued":    emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": emptyEnvelope,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo", cache: [sha: cachedGroup])
        #expect(result.count == 1)
        #expect(result.first?.jobs.first?.id == 999)
        #expect(transport.callCount == 3)
    }

    @Test func fetchActionGroups_singleRun_groupHasCorrectRepoScope() async {
        let sha = "scopecheck"
        let jobsData = jobsEnvelope([])
        let emptyEnvelope = runsEnvelope([])
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs?status=in_progress": runsEnvelope([
                minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil),
            ]),
            "repos/owner/repo/actions/runs?status=queued":    emptyEnvelope,
            "repos/owner/repo/actions/runs?status=completed": emptyEnvelope,
            "repos/owner/repo/actions/runs/1/jobs":           jobsData,
        ])
        let fetcher = WorkflowActionGroupFetcher(transport: transport)
        let result = await fetcher.fetchActionGroups(for: "owner/repo")
        #expect(result.first?.repo == "owner/repo")
    }
}
