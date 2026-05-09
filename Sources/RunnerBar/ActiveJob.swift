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

    /// Completion fraction 0.0–1.0 for the pie-progress dot, or `nil` (indeterminate)
    /// when the job is queued or step data is unavailable.
    var progressFraction: Double? {
        switch status {
        case "queued": return nil
        case "completed": return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            let done = steps.filter { $0.conclusion != nil }.count
            return Double(done) / Double(steps.count)
        }
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
        case "success": return "✓"
        case "failure": return "✗"
        case "skipped": return "⊘"
        case "cancelled": return "⊘"
        default: return status == "in_progress" ? "▶" : "·"
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

/// Raw API shape for a single job — Decodable only (no Encodable needed).
struct JobPayload: Decodable {
    /// GitHub-assigned job identifier.
    let id: Int
    /// Display name of the job.
    let name: String
    /// Current lifecycle status.
    let status: String
    /// Final outcome once the job finishes, if available.
    let conclusion: String?
    /// ISO 8601 timestamp when the runner picked up the job.
    let startedAt: String?
    /// ISO 8601 timestamp when the job entered the queue.
    let createdAt: String?
    /// ISO 8601 timestamp when the job finished.
    let completedAt: String?
    /// Deep-link URL on github.com for this job.
    let htmlUrl: String?
    /// Ordered list of step payloads, if included by the API.
    let steps: [JobStep]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
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
            steps: payload.steps ?? []
        )
    }
}

// MARK: - Codable helpers

/// Shared response wrapper — Decodable only (JobPayload is not Encodable).
struct JobsResponse: Decodable { let jobs: [JobPayload] }
