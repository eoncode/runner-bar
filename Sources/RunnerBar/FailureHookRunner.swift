import Foundation

// MARK: - FailureHookRunner
// #544: Fires the per-scope failure hook command when an ActionGroup transitions to failure.
//
// Called from RunnerStoreState.buildGroupState when a group is newly completed
// with a failure conclusion. Resolves all $TOKEN variables, writes the log tail
// to a temp file as $FAILURE_LOG, then shells out fire-and-forget.

enum FailureHookRunner {

    /// Call this whenever a group transitions to done with a failure conclusion.
    /// - Parameters:
    ///   - group: The completed ActionGroup.
    ///   - scope: The scope string (e.g. "psw-pwa/psw-pwa") the group belongs to.
    static func fireIfNeeded(group: ActionGroup, scope: String) {
        guard ScopeSettingsStore.failureHookEnabled(for: scope) else { return }
        guard let command = ScopeSettingsStore.failureHookCommand(for: scope),
              !command.isEmpty else {
            log("FailureHookRunner › hook enabled for \(scope) but no command set — skipping")
            return
        }
        guard isFailure(group: group) else { return }

        let resolved = resolveTokens(command, group: group, scope: scope)
        log("FailureHookRunner › firing hook for scope=\(scope) runID=\(group.id) command=\(resolved.prefix(200))")

        DispatchQueue.global(qos: .utility).async {
            Shell.run(resolved)
        }
    }

    // MARK: - Private

    private static func isFailure(group: ActionGroup) -> Bool {
        let failureConclusions: Set<String> = ["failure", "timed_out", "cancelled", "startup_failure"]
        return group.runs.contains { run in
            guard let conclusion = run.conclusion else { return false }
            return failureConclusions.contains(conclusion.lowercased())
        }
    }

    private static func resolveTokens(_ command: String, group: ActionGroup, scope: String) -> String {
        let runID      = group.id
        let branch     = group.headBranch ?? ""
        let sha        = group.headSha
        let workflow   = group.title
        let logPath    = writeLogFile(group: group, scope: scope)
        let baseURL    = "https://github.com/\(scope)"
        let repoURL    = baseURL
        let branchURL  = "\(baseURL)/tree/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)"
        let commitURL  = "\(baseURL)/commit/\(sha)"
        // Use first failed run ID for the run link
        let failedRunID = group.runs.first(where: {
            guard let c = $0.conclusion else { return false }
            return ["failure", "timed_out", "cancelled", "startup_failure"].contains(c.lowercased())
        }).map { String($0.id) } ?? runID
        let runURL     = "\(baseURL)/actions/runs/\(failedRunID)"

        return command
            .replacingOccurrences(of: "$SCOPE",         with: scope)
            .replacingOccurrences(of: "$BRANCH",        with: branch)
            .replacingOccurrences(of: "$RUN_ID",        with: "\(failedRunID)")
            .replacingOccurrences(of: "$COMMIT_SHA",    with: sha)
            .replacingOccurrences(of: "$WORKFLOW_NAME", with: workflow)
            .replacingOccurrences(of: "$FAILURE_LOG",   with: logPath)
            .replacingOccurrences(of: "$RUN_LINK",      with: runURL)
            .replacingOccurrences(of: "$COMMIT_LINK",   with: commitURL)
            .replacingOccurrences(of: "$BRANCH_LINK",   with: branchURL)
            .replacingOccurrences(of: "$REPO_LINK",     with: repoURL)
    }

    /// Writes a brief failure summary to a temp file and returns the path.
    private static func writeLogFile(group: ActionGroup, scope: String) -> String {
        let dir = FileManager.default.temporaryDirectory
        let name = "runnerbar-failure-\(scope.replacingOccurrences(of: "/", with: "-"))-\(group.id).log"
        let url = dir.appendingPathComponent(name)
        var lines: [String] = [
            "RunnerBar Failure Hook",
            "Scope:    \(scope)",
            "Branch:   \(group.headBranch ?? "unknown")",
            "SHA:      \(group.headSha)",
            "Workflow: \(group.title)",
            "---"
        ]
        for run in group.runs {
            if let conclusion = run.conclusion,
               ["failure", "timed_out", "cancelled", "startup_failure"].contains(conclusion.lowercased()) {
                lines.append("FAILED run \(run.id): conclusion=\(conclusion) workflow=\(run.name)")
            }
        }
        let content = lines.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
