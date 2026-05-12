import Foundation

// MARK: - ActiveJob model

/// Represents a single GitHub Actions job that is live or recently completed.
struct ActiveJob: Identifiable, Codable, Equatable {
    /// GitHub-assigned job identifier.
    let id: Int
    /// Display name of the job.
    let name: String
    /// Current lifecycle status (`queued`, `in_progress`, `completed`).
    let status: String
    /// Final outcome once the job finishes (`success`, `failure`, `cancelled`, etc.).
    let conclusion: String?
    /// When the job runner picked up the job.
    let startedAt: Date?
    /// When the job was added to the queue.
    let createdAt: Date?
    /// When the job finished.
    let completedAt: Date?
    /// Deep-link URL on github.com for this job.
    let htmlUrl: String?
    /// `true` when the job is shown as a dimmed historical entry.
    let isDimmed: Bool
    /// Ordered list of steps within this job.
    let steps: [JobStep]
    /// Name of the runner that picked up this job.
    /// `nil` when the job is still queued and hasn't been assigned yet.
    /// Used to determine local vs cloud icon on action rows.
    let runnerName: String?

    /// Human-readable elapsed time string.
    /// Queued jobs always show "00:00".
    /// Completed jobs return "--:--" when timestamps are unavailable.
    /// Live jobs fall back to createdAt while startedAt may not yet be set.
    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        if conclusion != nil {
            guard let start = startedAt, let end = completedAt else { return "--:--" }
            let secs = Int(end.timeIntervalSince(start))
            guard secs >= 0 else { return "--:--" }
            // swiftlint:disable:next identifier_name
            let m = secs / 60; let s = secs % 60
            return String(format: "%02d:%02d", m, s)
        }
        guard let start = startedAt ?? createdAt else { return "00:00" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let m = secs / 60; let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// `true` if this job ran (or is running) on a self-hosted local runner.
    /// Detection: runnerName is non-nil and does not match any GitHub-hosted
    /// name prefix. Returns `nil` when runnerName is unknown (job still queued).
    var isLocalRunner: Bool? {
        guard let name = runnerName else { return nil }
        let lower = name.lowercased()
        let githubPrefixes = [
            "github actions ",
            "ubuntu-",
            "macos-",
            "windows-",
            "buildjet-",
            "depot-",
        ]
        let isHosted = githubPrefixes.contains { lower.hasPrefix($0) }
        return !isHosted
    }

    // MARK: Codable
    // runnerName must appear in CodingKeys so Codable synthesis includes it.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
        case isDimmed
        case steps
        case runnerName = "runner_name"
    }
}

// MARK: - JobStep

/// A single step within an `ActiveJob`, matching the GitHub API `steps` array.
struct JobStep: Identifiable, Codable, Equatable {
    /// Step sequence number (1-based).
    let id: Int
    /// Display name of the step.
    let name: String
    /// Lifecycle status of the step.
    let status: String
    /// Conclusion of the step once finished.
    let conclusion: String?
    /// When this step started.
    let startedAt: Date?
    /// When this step finished.
    let completedAt: Date?

    /// SF Symbol or emoji icon representing the step's conclusion.
    var conclusionIcon: String {
        switch conclusion {
        case "success": return "\u{2713}"
        case "failure": return "\u{2717}"
        case "skipped": return "\u{2298}"
        case "cancelled": return "\u{2298}"
        default: return status == "in_progress" ? "\u{25B6}" : "\u{00B7}"
        }
    }

    /// Human-readable elapsed time for this step.
    var elapsed: String {
        let start = startedAt ?? Date()
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let m = secs / 60; let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id = "number"
        case name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - JobPayload (API decoding)

/// Raw API shape for a single job returned by `GET /repos/{owner}/{repo}/actions/jobs/{job_id}`.
struct JobPayload: Decodable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let createdAt: String?
    let completedAt: String?
    let htmlUrl: String?
    let steps: [StepPayload]?
    /// GitHub API field: the name of the runner that picked up this job.
    /// nil when the job hasn't been assigned to a runner yet (queued).
    let runnerName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
        case runnerName = "runner_name"
    }
}

// MARK: - StepPayload (API decoding)

/// Raw API shape for a single step inside a `JobPayload`.
/// Kept separate from `JobStep` so that `JobStep` remains `Codable` with `Date` fields
/// while the API always delivers timestamps as ISO-8601 strings.
struct StepPayload: Decodable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - ActiveJob factory

/// RunnerStore extension providing the `ActiveJob` factory method.
extension RunnerStore {
    /// Builds an `ActiveJob` from a decoded `JobPayload`.
    func makeActiveJob(
        from payload: JobPayload,
        iso: ISO8601DateFormatter,
        isDimmed: Bool
    ) -> ActiveJob {
        ActiveJob(
            id: payload.id,
            name: payload.name,
            status: payload.status,
            conclusion: payload.conclusion,
            startedAt: payload.startedAt.flatMap { iso.date(from: $0) },
            createdAt: payload.createdAt.flatMap { iso.date(from: $0) },
            completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
            htmlUrl: payload.htmlUrl,
            isDimmed: isDimmed,
            steps: (payload.steps ?? []).enumerated().map { idx, s in
                JobStep(
                    id: idx + 1,
                    name: s.name,
                    status: s.status,
                    conclusion: s.conclusion,
                    startedAt: s.startedAt.flatMap { iso.date(from: $0) },
                    completedAt: s.completedAt.flatMap { iso.date(from: $0) }
                )
            },
            runnerName: payload.runnerName
        )
    }
}

// MARK: - Codable helpers

/// Shared response wrapper used by ActionGroup.swift and RunnerStoreState.swift.
struct JobsResponse: Decodable { let jobs: [JobPayload] }
