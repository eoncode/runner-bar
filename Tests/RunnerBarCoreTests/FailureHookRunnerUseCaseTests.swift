// FailureHookRunnerUseCaseTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - FailureHookRunnerUseCaseTests

@Suite("FailureHookRunnerUseCase")
struct FailureHookRunnerUseCaseTests {

    // MARK: - Helpers

    /// Builds a SUT + spy pair. `hookEnabled`, `branch` and `localPath` mirror the
    /// most common `MockScopePreferencesStore` parameters used across tests.
    private func makeSUT(
        hookEnabled: Bool = true,
        branch: String? = nil,
        localPath: String = ""
    ) -> (sut: FailureHookRunnerUseCase, spy: SpyTerminalLauncher) {
        let spy = SpyTerminalLauncher()
        let store = MockScopePreferencesStore(
            hookEnabled: hookEnabled,
            branch: branch,
            localRepoPath: localPath
        )
        let sut = FailureHookRunnerUseCase(preferencesStore: store, terminalLauncher: spy)
        return (sut, spy)
    }

    /// Thin wrapper around `FailureHookRunnerUseCase.resolveTokens` with default
    /// `scope`, `jobs`, and `group` so individual tests only supply what varies.
    private func resolve(
        _ command: String,
        group: WorkflowActionGroup = .fixture(),
        scope: String = "owner/repo",
        jobs: [FailureHookRunnerUseCase.FailedJobResult] = [],
        localRepoPath: String = ""
    ) -> String {
        FailureHookRunnerUseCase.resolveTokens(
            command,
            group: group,
            scope: scope,
            jobs: jobs,
            localRepoPath: localRepoPath
        )
    }

    /// Thin wrapper around `FailureHookRunnerUseCase.buildLogContent` with default
    /// `scope` and `jobs` so individual tests only supply what varies.
    private func buildLog(
        group: WorkflowActionGroup,
        scope: String = "owner/repo",
        jobs: [FailureHookRunnerUseCase.FailedJobResult] = []
    ) -> String {
        FailureHookRunnerUseCase.buildLogContent(group: group, scope: scope, jobs: jobs)
    }

    // MARK: - fireIfNeeded — gate checks

    /// Hook disabled → terminal must not open regardless of group conclusion.
    @Test func fireIfNeededHookDisabledDoesNotOpenTerminal() async {
        let (sut, spy) = makeSUT(hookEnabled: false)
        await sut.fireIfNeeded(group: .fixture(conclusion: .failure), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Hook enabled but group did not fail → terminal must not open.
    @Test func fireIfNeededHookEnabledGroupNotFailedDoesNotOpenTerminal() async {
        let (sut, spy) = makeSUT()
        await sut.fireIfNeeded(group: .fixture(conclusion: .success), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Branch filter set, group branch does not match → terminal must not open.
    @Test func fireIfNeededBranchFilterMismatchDoesNotOpenTerminal() async {
        let (sut, spy) = makeSUT(branch: "main")
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "feature/x"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// All gates pass (hook enabled, group failed, branch matches) → terminal opens exactly once.
    /// `fetchFailedJobs` calls `ghAPI` which returns nil in CI (no token); jobs comes back empty.
    /// Terminal still opens once because all guards cleared before the network call.
    @Test func fireIfNeededAllGatesPassOpensTerminalOnce() async {
        let (sut, spy) = makeSUT(branch: "main")
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "main"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 1) }
    }

    // MARK: - resolveTokens — pure, no network

    /// `$LOCAL_PATH` is replaced with the supplied path.
    @Test func resolveTokensSubstitutesLocalPath() {
        let cmd = resolve("cd '$LOCAL_PATH'", localRepoPath: "/Users/andre/code/myrepo")
        #expect(cmd == "cd '/Users/andre/code/myrepo'")
    }

    /// A single-quote inside a path value is escaped as `'\''`.
    @Test func resolveTokensSingleQuoteInPathIsEscaped() {
        let cmd = resolve("cd '$LOCAL_PATH'", localRepoPath: "/Users/o'brien/code")
        #expect(cmd == "cd '/Users/o'\\''brien/code'")
    }

    /// A single-quote inside `$WORKFLOW_NAME` is correctly escaped.
    @Test func resolveTokensSingleQuoteInWorkflowNameIsEscaped() {
        let cmd = resolve(
            "echo '$WORKFLOW_NAME'",
            group: .fixture(workflowName: "CI: O'Brien's job")
        )
        #expect(cmd == "echo 'CI: O'\\''Brien'\\''s job'")
    }

    /// Single-quote content inside `$FAILURE_LOG` is correctly escaped end-to-end.
    @Test func resolveTokensSingleQuoteInFailureLogIsEscaped() {
        let cmd = resolve(
            "gemini -p '$FAILURE_LOG'",
            group: .fixture(conclusion: .failure, workflowName: "O'Brien CI")
        )
        #expect(!cmd.contains("workflow=O'Brien"))
        #expect(cmd.contains("workflow=O'\\''Brien"))
    }

    /// After resolution, none of the 11 placeholder tokens remain in the output.
    @Test func resolveTokensAllTokensPresentNoLiteralsRemain() {
        let template = "$LOCAL_PATH $SCOPE $BRANCH $COMMIT_SHA $RUN_ID $WORKFLOW_NAME $RUN_LINK $COMMIT_LINK $BRANCH_LINK $REPO_LINK $FAILURE_LOG"
        let result = resolve(template, localRepoPath: "/tmp")
        for token in ["$LOCAL_PATH", "$SCOPE", "$BRANCH", "$COMMIT_SHA", "$RUN_ID",
                      "$WORKFLOW_NAME", "$FAILURE_LOG", "$RUN_LINK", "$COMMIT_LINK",
                      "$BRANCH_LINK", "$REPO_LINK"] {
            #expect(!result.contains(token))
        }
    }

    // MARK: - buildLogContent

    /// When no jobs are supplied the fallback contains a FAILED run summary line.
    @Test func buildLogContentNoJobsReturnsFallbackSummary() {
        #expect(buildLog(group: .fixture(conclusion: .failure)).contains("FAILED run"))
    }

    /// When all runs have a non-hook conclusion the fallback is empty.
    @Test func buildLogContentNoFailedRunsReturnsEmpty() {
        #expect(buildLog(group: .fixture(conclusion: .success)).isEmpty)
    }
}
