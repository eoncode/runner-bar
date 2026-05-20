import Foundation

// MARK: - FailureHookRunner
// #544: Fires the per-scope failure hook command when an ActionGroup transitions to failure.
// #546: Resolves $LOCAL_PATH from ScopeSettingsStore.
// #552: Fetches failed job/step details on background thread before building $FAILURE_LOG.
//
// Called from RunnerStoreState.buildGroupState when a group is newly completed
// with a failure conclusion. Resolves all $TOKEN variables then opens Terminal.app
// via TerminalLauncher (AppleScript do script) so the command runs visibly.
//
// TOKEN RESOLUTION CONTRACT:
// ALL tokens are resolved in Swift before the command string is passed to
// /bin/zsh -c. There must be NO shell variables or $() subshells left in the
// command by the time it reaches the shell — special characters in log content,
// branch names, etc. would break shell parsing.
//
// $FAILURE_LOG inlines only the failed job/step names — succeeded steps are omitted.
// Wrap it in single quotes in your command:
//   gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo

enum FailureHookRunner {

    /// Default command used when no command has been explicitly saved for the scope.
    /// Shared with FailureHookCommandSheet for pre-population.
    static let defaultCommand =
        "cd $LOCAL_PATH && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo"

    /// Call this whenever a group transitions to done with a failure conclusion.
    /// Dispatches to a background thread, fetches failed job/step details, then fires.
    static func fireIfNeeded(group: ActionGroup, scope: String, callsite: String = "unknown") {
        log("FailureHookRunner › fireIfNeeded ENTER — callsite=\(callsite) scope=\(scope) groupID=\(group.id) groupTitle=\(group.title) headSha=\(group.headSha) groupStatus=\(group.groupStatus)")

        let hookEnabled = ScopeSettingsStore.failureHookEnabled(for: scope)
        log("FailureHookRunner › failureHookEnabled for scope=\(scope) → \(hookEnabled)")
        guard hookEnabled else {
            log("FailureHookRunner › SKIP — hook not enabled for scope=\(scope)")
            return
        }

        let storedCommand = ScopeSettingsStore.failureHookCommand(for: scope)
        log("FailureHookRunner › storedCommand for scope=\(scope) → \(storedCommand ?? "<nil — will use defaultCommand>")")
        let command = storedCommand ?? Self.defaultCommand
        log("FailureHookRunner › resolved command (first 200): \(command.prefix(200))")

        let failure = isFailure(group: group)
        log("FailureHookRunner › isFailure=\(failure) for groupID=\(group.id) runs=\(group.runs.map { "\($0.id):\($0.conclusion ?? "nil")" })")
        guard failure else {
            log("FailureHookRunner › SKIP — group is not a failure, groupID=\(group.id)")
            return
        }

        log("FailureHookRunner › ALL CHECKS PASSED — dispatching background task for scope=\(scope) groupID=\(group.id)")
        DispatchQueue.global(qos: .utility).async {
            log("FailureHookRunner › background thread START — fetching failed jobs for groupID=\(group.id)")
            let jobs = fetchFailedJobs(group: group, scope: scope)
            log("FailureHookRunner › background thread — fetchFailedJobs returned \(jobs.count) jobs: \(jobs.map { $0.name })")
            let resolved = resolveTokens(command, group: group, scope: scope, jobs: jobs)
            log("FailureHookRunner › background thread — resolved command (first 300): \(resolved.prefix(300))")
            log("FailureHookRunner › background thread — calling TerminalLauncher.open for groupID=\(group.id)")
            DispatchQueue.main.async {
                TerminalLauncher.open(command: resolved)
                log("FailureHookRunner › main thread — TerminalLauncher.open returned for groupID=\(group.id)")
            }
        }
    }

    // MARK: - Private

    private static let failureConclusions: Set<String> = ["failure", "timed_out", "cancelled", "startup_failure"]

    private static func isFailure(group: ActionGroup) -> Bool {
        group.runs.contains {
            guard let c = $0.conclusion else { return false }
            return failureConclusions.contains(c.lowercased())
        }
    }

    /// Fetches jobs (with steps) for all failed runs in the group.
    /// Blocking — must be called from a background thread.
    private static func fetchFailedJobs(group: ActionGroup, scope: String) -> [JobPayload] {
        var result: [JobPayload] = []
        var seenIDs = Set<Int>()
        for run in group.runs {
            guard let c = run.conclusion,
                  failureConclusions.contains(c.lowercased())
            else {
                log("FailureHookRunner › fetchFailedJobs — run \(run.id) conclusion=\(run.conclusion ?? "nil") — skipping (not failure)")
                continue
            }
            log("FailureHookRunner › fetchFailedJobs — fetching jobs for failed run=\(run.id) conclusion=\(c)")
            guard let data = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100") else {
                log("FailureHookRunner › fetchFailedJobs — ghAPI returned nil for run=\(run.id)")
                continue
            }
            guard let resp = try? JSONDecoder().decode(JobsResponse.self, from: data) else {
                log("FailureHookRunner › fetchFailedJobs — JSON decode failed for run=\(run.id) dataBytes=\(data.count)")
                continue
            }
            log("FailureHookRunner › fetchFailedJobs — run=\(run.id) decoded \(resp.jobs.count) jobs")
            for job in resp.jobs where seenIDs.insert(job.id).inserted {
                result.append(job)
            }
        }
        log("FailureHookRunner › fetchFailedJobs — total \(result.count) unique jobs returned")
        return result
    }

    /// Escapes a string so it is safe to embed between single-quotes in a shell command.
    private static func singleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Builds the failure log string. Only includes jobs and steps that failed —
    /// succeeded/skipped steps are omitted to keep the prompt tight.
    /// Falls back to run-level summary if job fetch returned nothing.
    private static func buildLogContent(
        group: ActionGroup,
        scope: String,
        jobs: [JobPayload]
    ) -> String {
        var lines: [String] = [
            "RunnerBar Failure Hook",
            "Scope:    \(scope)",
            "Branch:   \(group.headBranch ?? "unknown")",
            "SHA:      \(group.headSha)",
            "Workflow: \(group.title)",
            "---"
        ]

        guard !jobs.isEmpty else {
            log("FailureHookRunner › buildLogContent — no jobs, falling back to run-level summary")
            for run in group.runs {
                if let c = run.conclusion, failureConclusions.contains(c.lowercased()) {
                    lines.append("FAILED run \(run.id): conclusion=\(c) workflow=\(run.name)")
                }
            }
            return lines.joined(separator: "\n")
        }

        for job in jobs {
            let jobConclusion = job.conclusion ?? "unknown"
            lines.append("\nJOB: \(job.name) [\(jobConclusion)]")
            let failedSteps = (job.steps ?? []).filter {
                failureConclusions.contains(($0.conclusion ?? "").lowercased())
            }
            if failedSteps.isEmpty {
                lines.append("  (no failed steps reported)")
            } else {
                for step in failedSteps {
                    lines.append("  ✗ Step \(step.number): \(step.name) — \(step.conclusion ?? step.status)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func resolveTokens(
        _ command: String,
        group: ActionGroup,
        scope: String,
        jobs: [JobPayload]
    ) -> String {
        let localPath = ScopeSettingsStore.localRepoPath(for: scope) ?? ""
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
