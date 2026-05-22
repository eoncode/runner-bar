import Foundation

// MARK: - URL helpers

func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() {
        if part == "runs", idx + 1 < parts.count {
            return Int(parts[idx + 1])
        }
    }
    return nil
}

// MARK: - Fetch all jobs from active runs

func fetchActiveJobs(for scopeString: String) -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }
    let iso = ISO8601DateFormatter()
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=50"
    }

    for status in ["in_progress", "queued"] {
        guard let data = ghAPI(runsEndpoint(status: status)),
              let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else { continue }
        // swiftlint:disable for_where
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
        // swiftlint:enable for_where
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    for runID in runIDs {
        guard case .repo = scope else { continue }
        guard let data = ghAPI("\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=100"),
              let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(makeActiveJob(from: payload, iso: iso, isDimmed: false))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scopeString)")
    return jobs
}

// MARK: - Codable helpers

private struct WorkflowRunsResponse: Codable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

private struct WorkflowRun: Codable { let id: Int }

// MARK: - Runners

func fetchRunners(for scopeString: String) -> [Runner] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRunners › invalid scope: \(scopeString)")
        return []
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners"
    log("fetchRunners › \(endpoint)")
    guard let data = ghAPI(endpoint) else {
        log("fetchRunners › no data for scope: \(scopeString)")
        return []
    }
    guard let response = try? JSONDecoder().decode(RunnersResponse.self, from: data) else {
        log("fetchRunners › decode failed for scope: \(scopeString)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scopeString)")
    return response.runners
}

private struct RunnersResponse: Codable { let runners: [Runner] }

// MARK: - User orgs and repos

func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

func fetchUserRepos() -> [String] {
    guard let data = ghAPIPaginated("/user/repos?per_page=100&sort=updated") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

/// Compiled once at load time. The pattern is a string literal and never fails.
// swiftlint:disable:next force_try
private let _ansiRegex = try! NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

func fetchStepLog(jobID: Int, stepNumber: Int, scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchStepLog › invalid scope: \(scopeString)")
        return nil
    }
    guard case .repo = scope else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scopeString))")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/jobs/\(jobID)/logs"
    log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)")
    let (data, _) = runGHProcess(
        arguments: ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"],
        timeout: 30
    )
    guard let data, let raw = String(data: data, encoding: .utf8),
          !raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }
    let cleaned = stripAnsi(raw)
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []
    for line in lines {
        if line.contains("##[group]") {
            if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
            current = [line]
        } else {
            current.append(line)
        }
    }
    if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    log("fetchStepLog › parsed \(sections.count) section(s) from log")
    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
        log("fetchStepLog › no group markers, returning full raw log")
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        log(
            "fetchStepLog › stepNumber \(stepNumber) out of range "
            + "(sections=\(sections.count)), returning full log"
        )
        return cleaned
    }
    let section = sections[index]
    log("fetchStepLog › step \(stepNumber) → \(section.count)ch")
    return section.isEmpty ? cleaned : section
}

private func stripAnsi(_ input: String) -> String {
    _ansiRegex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}
