import Foundation

// MARK: - FailureHookRunner
// #544: Fires the per-scope failure hook command when an ActionGroup transitions to failure.
// #546: Resolves $LOCAL_PATH from ScopeSettingsStore.
// #552: Fetches failed job/step details on background thread before building $FAILURE_LOG.
//
// Called from RunnerStoreState.buildGroupState when a group is newly completed
// with a failure conclusion. Resolves all $TOKEN variables then shells out fire-and-forget.
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

    /// Call this whenever a group transitions to done with a failure conclusion.
    /// Dispatches to a background thread, fetches failed job/step details, then fires.
    static func fireIfNeeded(group: ActionGroup, scope: String) {
        guard ScopeSettingsStore.failureHookEnabled(for: scope) else { return }
        guard let command = ScopeSettingsStore.failureHookCommand(for: scope),
              !command.isEmpty else {
            log("FailureHookRunner › hook enabled for \(scope) but no command set — skipping")
            return
        }
        guard isFailure(group: group) else { return }

        DispatchQueue.global(qos: .utility).async {
            let jobs = fetchFailedJobs(group: group, scope: scope)
            let resolved = resolveTokens(command, group: group, scope: scope, jobs: jobs)
            log("FailureHookRunner › firing hook for scope=\(scope) runID=\(group.id) command=\(resolved.prefix(200))")
            Shell.run(resolved, timeout: 300)
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
                  failureConclusions.contains(c.lowercased()),
                  let data = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100"),
                  let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
            else { continue }
            for job in resp.jobs where seenIDs.insert(job.id).inserted {
                result.append(job)
            }
        }
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
