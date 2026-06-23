// FailureHookRunnerUseCase.swift
// RunnerBarCore
import Foundation

// MARK: - FailureHookRunnerUseCase

/// Testable, dependency-injected replacement for the `FailureHookRunner` static enum.
///
/// Fires the per-scope failure-hook terminal command when a `WorkflowActionGroup`
/// transitions to failure. All external dependencies (`ScopePreferencesStore`,
/// `TerminalLauncher`, and the network-layer `fetchFailedJobs`) are injected via
/// protocols/closures so the entire use-case can be unit-tested without hitting
/// `UserDefaults`, spawning Terminal.app, or making real network calls.
///
/// ## Migration from `FailureHookRunner`
/// `FailureHookRunner` is now a thin shim that creates this struct with the
/// production adapters (`DefaultScopePreferencesStore`, `DefaultTerminalLauncher`,
/// and the concrete `fetchFailedJobs` implementation from `RunnerBar`) and
/// delegates to `fireIfNeeded`. All business logic lives here.
///
/// ## Token resolution contract
/// ALL tokens are resolved in Swift before the command string is passed to
/// `/bin/zsh -c`. There must be NO shell variables or `$()` subshells left in the
/// command by the time it reaches the shell — special characters in log content,
/// branch names, etc. would break shell parsing.
///
/// ## Thread safety
/// `FailureHookRunnerUseCase` is `Sendable`. `fireIfNeeded` is `@concurrent` —
/// it runs on the cooperative thread pool, independent of the caller's isolation.
/// `TerminalLauncherProtocol.open(command:)` is dispatched via `MainActor.run`.
public struct FailureHookRunnerUseCase: Sendable {

    /// Default failure-hook command used when the user has not configured a
    /// custom command for the scope. `FailureHookRunner.defaultCommand` forwards
    /// to this constant — it is the canonical definition.
    public static let defaultCommand = "cd '$LOCAL_PATH' && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo"

    // MARK: Dependencies

    /// Reads per-scope failure-hook preferences from storage.
    public let preferencesStore: any ScopePreferencesStoreProtocol
    /// Opens Terminal.app with the resolved command. Must run on `@MainActor`.
    public let terminalLauncher: any TerminalLauncherProtocol
    /// Fetches failed job results for a group+scope. Injected so RunnerBarCore
    /// has no direct dependency on `ghAPI`, `LogFetcher`, or `log` (all in RunnerBar).
    /// Production wiring supplies the real network implementation; tests use a stub.
    public let jobFetcher: @Sendable (WorkflowActionGroup, String) async -> [FailedJobResult]

    /// Creates a use-case wired with the given dependencies.
    /// - Parameters:
    ///   - preferencesStore: Reads per-scope hook preferences.
    ///   - terminalLauncher: Opens Terminal.app with the resolved command.
    ///   - jobFetcher: Async closure that fetches `FailedJobResult`s for a group/scope.
    ///     Defaults to a no-op that returns `[]` so callers that don't care about
    ///     `$FAILURE_LOG` content can omit the parameter.
    public init(
        preferencesStore: any ScopePreferencesStoreProtocol,
        terminalLauncher: any TerminalLauncherProtocol,
        jobFetcher: @escaping @Sendable (WorkflowActionGroup, String) async -> [FailedJobResult] = { _, _ in [] }
    ) {
        self.preferencesStore = preferencesStore
        self.terminalLauncher = terminalLauncher
        self.jobFetcher = jobFetcher
    }

    // MARK: - Public API

    /// Call this whenever a group transitions to done with a failure conclusion.
    /// Fetches failed job/step details on the cooperative thread pool, resolves
    /// tokens, then fires the Terminal command on `@MainActor`.
    ///
    /// Annotated `@concurrent` per R8/R12: runs on the cooperative thread pool,
    /// independent of the caller's isolation domain.
    @concurrent
    public func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String = "unknown"
    ) async {
        let hookEnabled = preferencesStore.failureHookEnabled(for: scope)
        guard hookEnabled else { return }
        // Branch filter — skip if a branch filter is set and doesn't match.
        let filterBranch = preferencesStore.failureHookBranch(for: scope)
        if let filter = filterBranch {
            let groupBranch = group.headBranch ?? ""
            guard groupBranch == filter else { return }
        }
        let storedCommand = preferencesStore.failureHookCommand(for: scope)
        let command = storedCommand ?? FailureHookRunnerUseCase.defaultCommand
        let failure = Self.isFailure(group: group)
        guard failure else { return }
        let jobs = await jobFetcher(group, scope)
        let localPath = preferencesStore.localRepoPath(for: scope) ?? ""
        let resolved = Self.resolveTokens(command, group: group, scope: scope, jobs: jobs, localRepoPath: localPath)
        await MainActor.run {
            terminalLauncher.open(command: resolved)
        }
    }

    // MARK: - Internal (testable)

    /// Resolves all `$TOKEN` placeholders in `command` using data from `group`, `scope`, and `jobs`.
    ///
    /// Token map:
    /// - `$LOCAL_PATH`     — absolute path from `ScopePreferencesStoreProtocol.localRepoPath(for:)`
    /// - `$SCOPE`          — `owner/repo` string
    /// - `$BRANCH`         — head branch of the triggering run
    /// - `$COMMIT_SHA`     — full 40-char SHA of the triggering commit
    /// - `$RUN_ID`         — GitHub Actions run ID of the first *failed* run
    /// - `$WORKFLOW_NAME`  — display name of the workflow (from `WorkflowRunRef.name`)
    /// - `$RUN_LINK`       — deep link to the first failed run's Actions page on GitHub
    /// - `$COMMIT_LINK`    — deep link to the commit diff on GitHub
    /// - `$BRANCH_LINK`    — deep link to the branch on GitHub (percent-encoded)
    /// - `$REPO_LINK`      — deep link to the repository root on GitHub
    /// - `$FAILURE_LOG`    — raw log tail (last 150 lines) of the first failed job
    internal static func resolveTokens(
        _ command: String,
        group: WorkflowActionGroup,
        scope: String,
        jobs: [FailedJobResult],
        localRepoPath: String = ""
    ) -> String {
        let branch = group.headBranch ?? ""
        let sha = group.headSha
        let baseURL = "https://github.com/\(scope)"
        let failedRun = group.runs.first(where: { $0.conclusion?.isHookConclusion == true })
        let failedRunID = failedRun.map { String($0.id) } ?? group.id
        let runLink = failedRun?.htmlUrl ?? "\(baseURL)/actions/runs/\(failedRunID)"
        let workflowName = failedRun?.name ?? group.runs.first?.name ?? ""
        let commitLink = "\(baseURL)/commit/\(sha)"
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let branchLink = "\(baseURL)/tree/\(encodedBranch)"
        let repoLink = baseURL
        let logContent = buildLogContent(group: group, scope: scope, jobs: jobs)
        let escapedLog = singleQuoteEscape(logContent)
        return command
            .replacingOccurrences(of: "$LOCAL_PATH", with: singleQuoteEscape(localRepoPath))
            .replacingOccurrences(of: "$SCOPE", with: singleQuoteEscape(scope))
            .replacingOccurrences(of: "$BRANCH", with: singleQuoteEscape(branch))
            .replacingOccurrences(of: "$COMMIT_SHA", with: singleQuoteEscape(sha))
            .replacingOccurrences(of: "$RUN_ID", with: singleQuoteEscape(failedRunID))
            .replacingOccurrences(of: "$WORKFLOW_NAME", with: singleQuoteEscape(workflowName))
            .replacingOccurrences(of: "$RUN_LINK", with: runLink)
            .replacingOccurrences(of: "$COMMIT_LINK", with: commitLink)
            .replacingOccurrences(of: "$BRANCH_LINK", with: branchLink)
            .replacingOccurrences(of: "$REPO_LINK", with: repoLink)
            .replacingOccurrences(of: "$FAILURE_LOG", with: escapedLog)
    }

    /// Builds the `$FAILURE_LOG` content from failed job results.
    ///
    /// Falls back to a run-level summary (failed run IDs and conclusions) when
    /// `jobs` is empty. Otherwise concatenates available log tails, or
    /// failed step names when no log tail was fetched.
    internal static func buildLogContent(
        group: WorkflowActionGroup,
        scope _: String,
        jobs: [FailedJobResult]
    ) -> String {
        guard !jobs.isEmpty else {
            let lines: [String] = group.runs.compactMap { run in
                guard let conclusion = run.conclusion, conclusion.isHookConclusion else { return nil }
                return "FAILED run \(run.id): conclusion=\(conclusion.rawValue) workflow=\(run.name)"
            }
            return lines.joined(separator: "\n")
        }
        var parts: [String] = []
        for entry in jobs {
            let job = entry.job
            if let tail = entry.logTail, !tail.isEmpty {
                parts.append(tail)
            } else {
                let failedSteps = job.steps.filter {
                    guard let conclusion = $0.conclusion else { return false }
                    return conclusion.isHookConclusion
                }
                var lines: [String] = ["Job: \(job.name) [failed]"]
                if failedSteps.isEmpty {
                    lines.append("  (no failed steps reported)")
                } else {
                    for step in failedSteps {
                        let conclusionStr = step.conclusion?.rawValue ?? step.status.rawValue
                        lines.append("  x Step \(step.number): \(step.name) -- \(conclusionStr)")
                    }
                }
                parts.append(lines.joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Public types

    /// The result of fetching a single failed job, including its raw log tail.
    ///
    /// Returned by the `jobFetcher` closure injected into `FailureHookRunnerUseCase`.
    /// The production implementation in `FailureHookRunner` fetches data from the
    /// GitHub Actions API; test doubles return synthesised values.
    public struct FailedJobResult {
        /// The failed job payload returned by the GitHub Actions jobs API.
        public let job: JobPayload
        /// The last 150 lines of the job log, or `nil` if the log was unavailable.
        public let logTail: String?

        /// Creates a `FailedJobResult` with the given job payload and optional log tail.
        /// - Parameters:
        ///   - job: The failed `JobPayload` from the GitHub Actions jobs API.
        ///   - logTail: The last 150 lines of the job log, or `nil` if unavailable.
        public init(job: JobPayload, logTail: String?) {
            self.job = job
            self.logTail = logTail
        }
    }

    // MARK: - Private helpers

    /// Returns `true` if any run in `group` has a hook-triggering failure conclusion.
    private static func isFailure(group: WorkflowActionGroup) -> Bool {
        group.runs.contains { $0.conclusion?.isHookConclusion == true }
    }

    /// Escapes `str` so it is safe to embed between single-quotes in a shell command.
    /// Replaces every `'` with `'\''` — the standard POSIX single-quote escape.
    private static func singleQuoteEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "'", with: "'\\''")
    }
}
