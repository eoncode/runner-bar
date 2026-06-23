// FailureHookRunnerUseCaseTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - FailureHookRunnerUseCaseTests

@Suite("FailureHookRunnerUseCase")
struct FailureHookRunnerUseCaseTests {

    // MARK: - fireIfNeeded — gate checks

    /// Hook disabled → terminal must not open regardless of group conclusion.
    @Test func fireIfNeeded_hookDisabled_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: false),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(group: .fixture(conclusion: .failure), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Hook enabled but group did not fail → terminal must not open.
    @Test func fireIfNeeded_hookEnabled_groupNotFailed_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(group: .fixture(conclusion: .success), scope: "owner/repo")
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    /// Branch filter set, group branch does not match → terminal must not open.
    @Test func fireIfNeeded_branchFilterMismatch_doesNotOpenTerminal() async {
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true, branch: "main"),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "feature/x"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 0) }
    }

    // MARK: - resolveTokens — pure, no network

    /// `$LOCAL_PATH` is replaced with the supplied path.
    @Test func resolveTokens_substitutesLocalPath() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "cd '$LOCAL_PATH'",
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/Users/andre/code/myrepo"
        )
        #expect(cmd == "cd '/Users/andre/code/myrepo'")
    }

    /// A single-quote inside a path value is escaped as `'\''`.
    @Test func resolveTokens_singleQuoteInPath_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "cd '$LOCAL_PATH'",
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/Users/o'brien/code"
        )
        #expect(cmd == "cd '/Users/o'\\''brien/code'")
    }

    /// After resolution, none of the 11 placeholder tokens remain in the output.
    ///
    /// Covers both shell-escaped tokens ($LOCAL_PATH, $SCOPE, $BRANCH, $COMMIT_SHA,
    /// $RUN_ID, $WORKFLOW_NAME, $FAILURE_LOG) and verbatim URL tokens ($RUN_LINK,
    /// $COMMIT_LINK, $BRANCH_LINK, $REPO_LINK).
    @Test func resolveTokens_allTokensPresent_noLiteralsRemain() {
        let template = "$LOCAL_PATH $SCOPE $BRANCH $COMMIT_SHA $RUN_ID $WORKFLOW_NAME $RUN_LINK $COMMIT_LINK $BRANCH_LINK $REPO_LINK $FAILURE_LOG"
        let result = FailureHookRunnerUseCase.resolveTokens(
            template,
            group: .fixture(),
            scope: "owner/repo",
            jobs: [],
            localRepoPath: "/tmp"
        )
        // Shell-escaped tokens
        #expect(!result.contains("$LOCAL_PATH"))
        #expect(!result.contains("$SCOPE"))
        #expect(!result.contains("$BRANCH"))
        #expect(!result.contains("$COMMIT_SHA"))
        #expect(!result.contains("$RUN_ID"))
        #expect(!result.contains("$WORKFLOW_NAME"))
        #expect(!result.contains("$FAILURE_LOG"))
        // URL tokens (substituted verbatim — percent-encoded, no shell-special chars)
        #expect(!result.contains("$RUN_LINK"))
        #expect(!result.contains("$COMMIT_LINK"))
        #expect(!result.contains("$BRANCH_LINK"))
        #expect(!result.contains("$REPO_LINK"))
    }

    // MARK: - buildLogContent

    /// When no jobs are supplied the fallback contains a FAILED run summary line.
    @Test func buildLogContent_noJobs_returnsFallbackSummary() {
        let result = FailureHookRunnerUseCase.buildLogContent(
            group: .fixture(conclusion: .failure),
            scope: "owner/repo",
            jobs: []
        )
        #expect(result.contains("FAILED run"))
    }

    /// When all runs have a non-hook conclusion the fallback is empty.
    @Test func buildLogContent_noFailedRuns_returnsEmpty() {
        let result = FailureHookRunnerUseCase.buildLogContent(
            group: .fixture(conclusion: .success),
            scope: "owner/repo",
            jobs: []
        )
        #expect(result.isEmpty)
    }
}
