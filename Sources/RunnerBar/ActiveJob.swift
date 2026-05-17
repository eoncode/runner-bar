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
    let runnerName: String?

    /// Typed status derived from the raw `status` + `conclusion` strings.
    /// Maps to `GroupStatus` so `DonutStatusView` can be used directly on job rows.
    var typedStatus: GroupStatus {
        switch status {
        case "in_progress": return .inProgress
        case "queued":      return .queued
        case "completed":
            switch conclusion {
            case "success":             return .success
            case "failure", "timed_out": return .failed
            default:                    return .completed
            }
        default: return .unknown
        }
    }

    /// Step progress fraction 0–1 for in-progress jobs.
    /// Returns nil when there are no steps or the job isn't in-progress.
    var progressFraction: Double? {
        guard status == "in_progress", !steps.isEmpty else { return nil }
        let done = steps.filter { $0.conclusion != nil }.count
        return Double(done) / Double(steps.count)
    }

    /// Human-readable elapsed wall-clock string for this job in `MM:SS` format.
    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        if conclusion != nil {
            guard let start = startedAt, let end = completedAt else { return "--:--" }
            let secs = Int(end.timeIntervalSince(start))
            guard secs >= 0 else { return "--:--" }
            // swiftlint:disable:next identifier_name
            let m = secs / 60
            // swiftlint:disable:next identifier_name
            let s = secs % 60
            return String(format: "%02d:%02d", m, s)
        }
        guard let start = startedAt ?? createdAt else { return "00:00" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let m = secs / 60
        // swiftlint:disable:next identifier_name
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// `true` if this job ran (or is running) on a self-hosted local runner.
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

struct JobStep: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
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
        // swiftlint:disable:next identifier_name
        let m = secs / 60
        // swiftlint:disable:next identifier_name
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
            steps: (payload.steps ?? []).map { stepPayload in
                JobStep(
                    id: stepPayload.number,
                    name: stepPayload.name,
                    status: stepPayload.status,
                    conclusion: stepPayload.conclusion,
                    startedAt: stepPayload.startedAt.flatMap { iso.date(from: $0) },
                    completedAt: stepPayload.completedAt.flatMap { iso.date(from: $0) }
                )
            },
            runnerName: payload.runnerName
        )
    }
}

// MARK: - Codable helpers

struct JobsResponse: Decodable { let jobs: [JobPayload] }
