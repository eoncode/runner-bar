// SaveRunnerEditsUseCaseTests.swift
// RunnerBarCoreTests
// Unit tests for SaveRunnerEditsUseCase — Phase 5 (#1300).
import Foundation
import RunnerBarCore
import Testing

// MARK: - Helpers

private func makeRunner(
    runnerName: String = "test-runner",
    agentId: Int? = 42,
    gitHubUrl: String? = "https://github.com/owner/repo",
    installPath: String? = testRunnerInstallPath
) -> RunnerModel {
    RunnerModel(
        runnerName: runnerName,
        gitHubUrl: gitHubUrl,
        agentId: agentId,
        workFolder: nil,
        installPath: installPath,
        isRunning: false
    )
}

// MARK: - UseCase factory

private func makeUseCase(
    labels: SpyLabelsService = SpyLabelsService(),
    config: SpyConfigStore = SpyConfigStore(),
    proxy: SpyProxyStore = SpyProxyStore()
) -> SaveRunnerEditsUseCase {
    SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)
}

// MARK: - Tests

@Suite("SaveRunnerEditsUseCase")
struct SaveRunnerEditsUseCaseTests {

    @Test("returns .success when no fields changed")
    func noChanges() async {
        let runner   = makeRunner()
        let draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        let labels   = SpyLabelsService()
        let config   = SpyConfigStore()
        let proxy    = SpyProxyStore()
        let useCase  = makeUseCase(labels: labels, config: config, proxy: proxy)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        #expect(result == .success)
        #expect(await labels.callCount == 0)
        #expect(await !config.saveCalled)
        #expect(await !proxy.saveCalled)
    }

    @Test("aborts entire commit when labels API returns nil")
    func labelsAPIFailureAborts() async {
        let runner   = makeRunner()
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.labelsText = "ci, fast"

        let labels  = SpyLabelsService()
        await labels.setUp(result: nil)
        let config  = SpyConfigStore()
        let proxy   = SpyProxyStore()
        let useCase = makeUseCase(labels: labels, config: config, proxy: proxy)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.count == 1)
        #expect(msgs[0].contains("GitHub API"))
        #expect(await !config.saveCalled)
        #expect(await !proxy.saveCalled)
    }

    @Test("accumulates JSON error but continues to proxy step")
    func jsonWriteFailureContinues() async {
        let runner   = makeRunner()
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.workFolder = "custom_work"
        draft.proxyUrl   = "http://proxy.example.com"

        let config  = SpyConfigStore()
        await config.setUp(shouldThrowOnSave: true)
        let proxy   = SpyProxyStore()
        let useCase = makeUseCase(config: config, proxy: proxy)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.contains(where: { $0.contains(".runner JSON") }))
        #expect(await proxy.saveCalled)
    }

    @Test("accumulates proxy error independently of JSON success")
    func proxyWriteFailureAccumulated() async {
        let runner   = makeRunner()
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.proxyUrl = "http://proxy.example.com"

        let proxy   = SpyProxyStore()
        await proxy.setUp(shouldThrowOnSave: true)
        let useCase = makeUseCase(proxy: proxy)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.contains(where: { $0.contains("proxy") }))
    }

    @Test("calls labelsService with correct scope and runnerID")
    func labelsCalledWithCorrectArgs() async {
        let runner   = makeRunner(agentId: 99, gitHubUrl: "https://github.com/myorg/myrepo")
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.labelsText = "gpu, large"

        let labels  = SpyLabelsService()
        await labels.setUp(result: ["gpu", "large"])
        let useCase = makeUseCase(labels: labels)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        #expect(result == .success)
        #expect(await labels.callCount == 1)
        #expect(await labels.lastScope == "myorg/myrepo")
        #expect(await labels.lastRunnerID == 99)
        #expect(await labels.lastLabels == ["gpu", "large"])
    }

    @Test("returns failure when installPath is nil and JSON changes pending")
    func missingInstallPathForJSON() async {
        let runner   = makeRunner(installPath: nil)
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.workFolder = "other"

        let useCase = makeUseCase()

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure")
            return
        }
        #expect(msgs.contains(where: { $0.contains("Install path") }))
    }

    @Test("returns failure when installPath is nil and proxy changes pending")
    func missingInstallPathForProxy() async {
        // Runner has no installPath; only a proxy field is changed so Step 2
        // (JSON) is skipped and we land directly on the Step 3 guard.
        let runner   = makeRunner(installPath: nil)
        var draft    = RunnerEditDraft(runner: runner)
        let original = RunnerEditDraft(runner: runner)
        draft.proxyUrl = "http://proxy.example.com"

        let proxy   = SpyProxyStore()
        let useCase = makeUseCase(proxy: proxy)

        let result = await useCase.execute(runner: runner, draft: draft, original: original)

        guard case .failure(let msgs) = result else {
            Issue.record("expected .failure, got .success")
            return
        }
        #expect(msgs.contains(where: { $0.contains("Install path") }))
        #expect(await !proxy.saveCalled)
    }
}
