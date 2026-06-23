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

    /// All gates pass (hook enabled, group failed, branch matches) → terminal opens exactly once.
    ///
    /// `fetchFailedJobs` makes a real `ghAPI` network call inside this test. In CI there
    /// is no token, so `ghAPI` returns `nil` and `jobs` comes back empty — the test still
    /// passes because `fireIfNeeded` always opens the terminal once all guards clear,
    /// regardless of whether jobs were fetched. This is acceptable for an integration-style
    /// assertion on the success path. A fully pure variant would require extracting
    /// `fetchFailedJobs` behind an injectable protocol (tracked for a future issue).
    @Test func fireIfNeeded_allGatesPass_opensTerminalOnce() async { // NOSONAR — intentional network-dependent happy-path test; see doc comment
        let spy = SpyTerminalLauncher()
        let sut = FailureHookRunnerUseCase(
            preferencesStore: MockScopePreferencesStore(hookEnabled: true, branch: "main"),
            terminalLauncher: spy
        )
        await sut.fireIfNeeded(
            group: .fixture(conclusion: .failure, branch: "main"),
            scope: "owner/repo"
        )
        await MainActor.run { #expect(spy.openCallCount == 1) }
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

    /// A single-quote inside `$WORKFLOW_NAME` is correctly escaped.
    ///
    /// Workflow names are user-controlled on GitHub and represent the highest-risk
    /// shell-injection surface among the resolved tokens. This test pins the escaping
    /// contract: a name like `"CI: O'Brien's job"` must produce `O'\''Brien'\''s job`
    /// so it is safe to embed between single quotes in the command template.
    @Test func resolveTokens_singleQuoteInWorkflowName_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "echo '$WORKFLOW_NAME'",
            group: .fixture(workflowName: "CI: O'Brien's job"),
            scope: "owner/repo",
            jobs: []
        )
        #expect(cmd == "echo 'CI: O'\\''Brien'\\''s job'")
    }

    /// Single-quote content inside `$FAILURE_LOG` is correctly escaped end-to-end.
    ///
    /// `$FAILURE_LOG` is the highest-volume token — it is populated from raw CI log output
    /// which can contain arbitrary text including single quotes. This test drives the full
    /// path: `buildLogContent` emits a run-summary line whose workflow name contains a
    /// single quote, `resolveTokens` applies `singleQuoteEscape` to the log block, and
    /// the resulting command must contain no unescaped `'` that would break shell parsing.
    ///
    /// The fixture uses `jobs: []` so `buildLogContent` takes the run-level fallback path,
    /// producing a line of the form `FAILED run 999: conclusion=failure workflow=O'Brien CI`.
    /// After escaping, every `'` in that line becomes `'\''`.
    @Test func resolveTokens_singleQuoteInFailureLog_isEscaped() {
        let cmd = FailureHookRunnerUseCase.resolveTokens(
            "gemini -p '$FAILURE_LOG'",
            group: .fixture(conclusion: .failure, workflowName: "O'Brien CI"),
            scope: "owner/repo",
            jobs: []
        )
        // The log will contain "workflow=O'Brien CI". After singleQuoteEscape that
        // apostrophe becomes '\'' — verify no raw single-quote remnant inside the token.
        // We check the resolved command does not contain the unescaped form.
        #expect(!cmd.contains("workflow=O'Brien"))
        // And the escaped form is present.
        #expect(cmd.contains("workflow=O'\\''Brien"))
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
