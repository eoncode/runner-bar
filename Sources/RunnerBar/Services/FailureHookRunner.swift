// FailureHookRunner.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - FailureHookRunner

/// Fires the per-scope failure-hook terminal command when a `WorkflowActionGroup` transitions to failure.
///
/// Feature introduced in #544. Resolves `$LOCAL_PATH` from `ScopePreferencesStore` (see #546),
/// fetches failed job/step details on a background thread before building `$FAILURE_LOG` (see #552),
/// and applies an optional branch filter before firing (see #560).
///
/// Called indirectly from `RunnerStore.buildGroupState` (see `RunnerPollState.swift`)
/// via `PollResultBuilder.buildGroupState`'s `fireFailureHook` closure parameter.
/// Resolves all `$TOKEN` variables via `resolveTokens(_:group:scope:jobs:)` then opens
/// Terminal.app via `TerminalLauncher` (AppleScript `do script`) so the command runs visibly.
///
/// **Token resolution contract:**
/// ALL tokens are resolved in Swift before the command string is passed to
/// `/bin/zsh -c`. There must be NO shell variables or `$()` subshells left in the
/// command by the time it reaches the shell — special characters in log content,
/// branch names, etc. would break shell parsing.
///
/// `$FAILURE_LOG` contains the raw log tail of the failed job (last 150 lines).
/// If no log is available it falls back to failed job/step names only.
/// Wrap it in single quotes in your command:
/// ```
/// gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo
/// ```
///
/// Other tokens (`$LOCAL_PATH`, `$SCOPE`, `$BRANCH`, `$COMMIT_SHA`, `$RUN_ID`,
/// `$WORKFLOW_NAME`, `$RUN_LINK`, `$COMMIT_LINK`, `$BRANCH_LINK`, `$REPO_LINK`) are
/// available for use in the command but are NOT injected automatically —
/// the user must include them as placeholders in their command string.
enum FailureHookRunner {

    /// Default command used when no command has been explicitly saved for the scope.
    /// Shared with FailureHookCommandSheet for pre-population.
    static let defaultCommand = "cd $LOCAL_PATH && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo"

    /// Call this whenever a group transitions to done with a failure conclusion.
    /// Spawns a detached background Task, fetches failed job/step details, then fires.
    static func fireIfNeeded(group: WorkflowActionGroup, scope: String, callsite: String = "unknown") {
        log("FailureHookRunner › fireIfNeeded ENTER — callsite=\(callsite) scope=\(scope) groupID=\(group.id) groupTitle=\(group.title) headSha=\(group.headSha) groupStatus=\(group.groupStatus)")
        let hookEnabled = ScopePreferencesStore.failureHookEnabled(for: scope)
        log("FailureHookRunner › failureHookEnabled for scope=\(scope) → \(hookEnabled)")
        guard hookEnabled else {
            log("FailureHookRunner › SKIP — hook not enabled for scope=\(scope)")
            return
        }
        // #560: Branch filter — skip if a branch filter is set and doesn’t match
        let filterBranch = ScopePreferencesStore.failureHookBranch(for: scope)
        if let filter = filterBranch {
            let groupBranch = group.headBranch ?? ""
            guard groupBranch == filter else {
                log("FailureHookRunner › SKIP — branch filter '\(filter)' ≠ group branch '\(groupBranch)'")
                return
            }
            log("FailureHookRunner › branch filter '\(filter)' MATCHED group branch '\(groupBranch)'")
        }
        let storedCommand = ScopePreferencesStore.failureHookCommand(for: scope)
        log("FailureHookRunner › storedCommand for scope=\(scope) → \(storedCommand ?? "<nil — will use defaultCommand>")")
        let command = storedCommand ?? Self.defaultCommand
        log("FailureHookRunner › resolved command (first 200): \(command.prefix(200))")
        let failure = isFailure(group: group)
        let runSummary = group.runs.map { "\($0.id):\($0.conclusion ?? "nil")" }.joined(separator: ",")
        log("FailureHookRunner › isFailure=\(failure) for groupID=\(group.id) runs=\(runSummary)")
        guard failure else {
            log("FailureHookRunner › SKIP — group is not a failure, groupID=\(group.id)")
            return
        }
        log("FailureHookRunner › ALL CHECKS PASSED — dispatching background Task for scope=\(scope) groupID=\(group.id)")
        Task.detached(priority: .utility) {
            log("FailureHookRunner › Task START — fetching failed jobs for groupID=\(group.id)")
            let jobs = await fetchFailedJobs(group: group, scope: scope)
            log("FailureHookRunner › Task — fetchFailedJobs returned \(jobs.count) jobs: \(jobs.map { $0.job.name })")
            let resolved = resolveTokens(command, group: group, scope: scope, jobs: jobs)
            log("FailureHookRunner › Task — resolved command (first 300): \(resolved.prefix(300))")
            log("FailureHookRunner › Task — calling TerminalLauncher.open for groupID=\(group.id)")
            await MainActor.run {
                TerminalLauncher.open(command: resolved)
                log("FailureHookRunner › main actor — TerminalLauncher.open returned for groupID=\(group.id)")
            }
        }
    }

    // MARK: - Private

    /// Raw-string failure conclusions matching GitHub API values.
    /// WorkflowRunRef.conclusion is String? so we stay in String-land here.
    private static let failureConclusions: Set<String> = ["failure", "timed_out", "cancelled", "startup_failure"]

    /// Returns `true` when at least one run in `group` has a failure-class conclusion.
    private static func isFailure(group: WorkflowActionGroup) -> Bool {
        group.runs.contains {
            guard let c = $0.conclusion else { return false }
            return failureConclusions.contains(c.lowercased())
        }
    }

    /// The result of fetching a single failed job, including its raw log tail.
    private struct FailedJobResult {
        /// The job payload returned by the GitHub Jobs API.
        let job: JobPayload
        /// The last 150 lines of the job log, or `nil` if the log was unavailable.
        let logTail: String?
    }

    /// Fetches jobs (with steps) and raw log tail for all failed runs in the group.
    /// - Note: `fetchJobLog` → `RunnerBarCore/Services/LogFetcher.swift`.
    ///         `ghAPI` → `RunnerBarCore/GitHub/GitHubTransportShim.swift` (shim),
    ///                   `RunnerBar/GitHub/GitHubURLSessionTransport.swift` (app target).
    private static func fetchFailedJobs(group: WorkflowActionGroup, scope: String) async -> [FailedJobResult] {
        var result: [FailedJobResult] = []
        var seenIDs = Set<Int>()
        for run in group.runs {
            guard let c = run.conclusion, failureConclusions.contains(c.lowercased()) else {
                log("FailureHookRunner › fetchFailedJobs — run \(run.id) conclusion=\(run.conclusion ?? "nil") — skipping (not failure)")
                continue
            }
            log("FailureHookRunner › fetchFailedJobs — fetching jobs for failed run=\(run.id) conclusion=\(c)")
            guard let data = await ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100") else {
                log("FailureHookRunner › fetchFailedJobs — ghAPI returned nil for run=\(run.id)")
                continue
            }
            guard let resp = try? JSONDecoder().decode(JobsResponse.self, from: data) else {
                log("FailureHookRunner › fetchFailedJobs — JSON decode failed for run=\(run.id) dataBytes=\(data.count)")
                continue
            }
            log("FailureHookRunner › fetchFailedJobs — run=\(run.id) decoded \(resp.jobs.count) jobs")
            for job in resp.jobs where seenIDs.insert(job.id).inserted {
                let tail: String?
                if let jobConclusion = job.conclusion,
                   failureConclusions.contains(jobConclusion.rawValue.lowercased()) {
                    log("FailureHookRunner › fetchFailedJobs — fetching log for failed jobID=\(job.id) name=\(job.name)")
                    if let fullLog = await fetchJobLog(jobID: job.id, scope: scope) {
                        let lines = fullLog.components(separatedBy: "\n")
                        let kept = lines.suffix(150).joined(separator: "\n")
                        tail = kept
                        log("FailureHookRunner › fetchFailedJobs — jobID=\(job.id) log lines=\(lines.count) kept last 150")
                    } else {
                        tail = nil
                        log("FailureHookRunner › fetchFailedJobs — jobID=\(job.id) fetchJobLog returned nil")
                    }
                } else {
                    tail = nil
                }
                result.append(FailedJobResult(job: job, logTail: tail))
            }
        }
        log("FailureHookRunner › fetchFailedJobs — total \(result.count) unique jobs returned")
        return result
    }

    /// Escapes `s` so it is safe to embed between single-quotes in a shell command.
    /// Replaces every `'` with `'\''` — the standard POSIX single-quote escape.
    private static func singleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''") 
    }

    /// Builds the `$FAILURE_LOG` content from failed job results.
    ///
    /// Falls back to a run-level summary (failed run IDs and conclusions) when
    /// `jobs` is empty. Otherwise concatenates available log tails, or
    /// failed step names when no log tail was fetched.
    private static func buildLogContent(
        group: WorkflowActionGroup,
        scope _: String,
        jobs: [FailedJobResult]
    ) -> String {
        guard !jobs.isEmpty else {
            log("FailureHookRunner › buildLogContent — no jobs, falling back to run-level summary")
            var lines: [String] = []
            for run in group.runs {
                if let c = run.conclusion, failureConclusions.contains(c.lowercased()) {
                    lines.append("FAILED run \(run.id): conclusion=\(c) workflow=\(run.name)")
                }
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
                    guard let c = $0.conclusion else { return false }
                    return failureConclusions.contains(c.rawValue.lowercased())
                }
                var lines: [String] = ["Job: \(job.name) [failed]"]
                if failedSteps.isEmpty {
                    lines.append("  (no failed steps reported)")
                } else {
                    for step in failedSteps {
                        lines.append("  ✗ Step \(step.number): \(step.name) — \(step.conclusion?.rawValue ?? step.status.rawValue)")
                    }
                }
                parts.append(lines.joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Replaces all `$TOKEN` placeholders in `command` with their resolved values.
    ///
    /// Tokens resolved: `$LOCAL_PATH`, `$SCOPE`, `$BRANCH`, `$COMMIT_SHA`,
    /// `$RUN_ID`, `$WORKFLOW_NAME`, `$FAILURE_LOG`, `$RUN_LINK`,
    /// `$COMMIT_LINK`, `$BRANCH_LINK`, `$REPO_LINK`.
    private static func resolveTokens(
        _ command: String,
        group: WorkflowActionGroup,
        scope: String,
        jobs: [FailedJobResult]
    ) -> String {
        let localPath = ScopePreferencesStore.localRepoPath(for: scope) ?? ""
        let branch = group.headBranch ?? ""
        let sha = group.headSha
        let workflow = group.title
        let baseURL = "https://github.com/\(scope)"
        let branchURL = "\(baseURL)/tree/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)"
        let commitURL = "\(baseURL)/commit/\(sha)"
        let failedRunID = group.runs.first(where: {
            guard let c = $0.conclusion else { return false }
            return failureConclusions.contains(c.lowercased())
        }).map { String($0.id) } ?? group.id
        let runURL = "\(baseURL)/actions/runs/\(failedRunID)"
        let logContent = singleQuoteEscape(buildLogContent(group: group, scope: scope, jobs: jobs))
        log("FailureHookRunner › resolveTokens — $LOCAL_PATH='\(localPath)' $BRANCH='\(branch)' $RUN_ID='\(failedRunID)' $COMMIT_SHA='\(sha)' logContentBytes=\(logContent.count)")
        return command
            .replacingOccurrences(of: "$LOCAL_PATH", with: localPath)
            .replacingOccurrences(of: "$SCOPE", with: scope)
            .replacingOccurrences(of: "$BRANCH", with: branch)
            .replacingOccurrences(of: "$RUN_ID", with: "\(failedRunID)")
            .replacingOccurrences(of: "$COMMIT_SHA", with: sha)
            .replacingOccurrences(of: "$WORKFLOW_NAME", with: workflow)
            .replacingOccurrences(of: "$FAILURE_LOG", with: logContent)
            .replacingOccurrences(of: "$RUN_LINK", with: runURL)
            .replacingOccurrences(of: "$COMMIT_LINK", with: commitURL)
            .replacingOccurrences(of: "$BRANCH_LINK", with: branchURL)
            .replacingOccurrences(of: "$REPO_LINK", with: baseURL)
    }
}
