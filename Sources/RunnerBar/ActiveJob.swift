// swiftlint:disable identifier_name
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
    let runnerName: String?

    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        if conclusion != nil {
            guard let start = startedAt, let end = completedAt else { return "--:--" }
            let secs = Int(end.timeIntervalSince(start))
            guard secs >= 0 else { return "--:--" }
            let m = secs / 60
            let s = secs % 60
            return String(format: "%02d:%02d", m, s)
        }
        guard let start = startedAt ?? createdAt else { return "00:00" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

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

    var conclusionIcon: String {
        switch conclusion {
        case "success": return "\u{2713}"
        case "failure": return "\u{2797}"
        case "skipped": return "\u{2298}"
        case "cancelled": return "\u{2298}"
        default: return status == "in_progress" ? "\u{25B6}" : "\u{00B7}"
        }
    }

    var elapsed: String {
        let start = startedAt ?? Date()
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        let m = secs / 60
        let s = secs % 60
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

/// Raw API shape for a single job.
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

/// Raw API type for a single step inside a `JobPayload`.
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

extension RunnerStore {
    /// Builds an `ActiveJob` from a decoded `JobPayload`.
    func makeActiveJob(
        from payload: JobPayload,
        iso: ISO8601DateFormatter,
        isDimmed: Bool
    ) -> ActiveJob {
        let steps: [JobStep] = (payload.steps ?? []).map { stepPayload in
            JobStep(
                id: stepPayload.number,
                name: stepPayload.name,
                status: stepPayload.status,
                conclusion: stepPayload.conclusion,
                startedAt: stepPayload.startedAt.flatMap { iso.date(from: $0) },
                completedAt: stepPayload.completedAt.flatMap { iso.date(from: $0) }
            )
        }
        return ActiveJob(
            id: payload.id,
            name: payload.name,
            status: payload.status,
            conclusion: payload.conclusion,
            startedAt: payload.startedAt.flatMap { iso.date(from: $0) },
            createdAt: payload.createdAt.flatMap { iso.date(from: $0) },
            completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
            htmlUrl: payload.htmlUrl,
            isDimmed: isDimmed,
            steps: steps,
            runnerName: payload.runnerName
        )
    }
}

/// Shared response wrapper.
struct JobsResponse: Decodable { let jobs: [JobPayload] }
// swiftlint:enable identifier_name
