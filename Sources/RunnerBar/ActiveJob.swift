import Foundation

// MARK: - ActiveJob

/// A single GitHub Actions job as displayed in the popover.
struct ActiveJob: Identifiable, Equatable {
    /// GitHub job ID.
    let id: Int
    /// Human-readable job name.
    let name: String
    /// Current job status (`queued`, `in_progress`, `completed`).
    let status: String
    /// Final conclusion once completed (`success`, `failure`, `cancelled`, etc.).
    let conclusion: String?
    /// ISO-8601 string when the job started, if available.
    let startedAt: Date?
    /// ISO-8601 string when the job was created/queued.
    let createdAt: Date?
    /// ISO-8601 string when the job completed, if available.
    let completedAt: Date?
    /// URL to the job on GitHub.com.
    let htmlUrl: String
    /// When true, this job is shown dimmed (recently completed).
    var isDimmed: Bool
    /// Individual steps within the job.
    let steps: [JobStep]
}

// MARK: - JobStep

/// A single step within a GitHub Actions job.
struct JobStep: Codable, Equatable {
    /// Step sequence number (1-based).
    let number: Int
    /// Step name as shown in GitHub UI.
    let name: String
    /// Current step status (`queued`, `in_progress`, `completed`).
    let status: String
    /// Final conclusion once completed (`success`, `failure`, `skipped`, etc.).
    let conclusion: String?
    /// ISO-8601 start timestamp.
    let startedAt: String?
    /// ISO-8601 completion timestamp.
    let completedAt: String?

    /// Maps JSON snake_case keys to Swift camelCase properties.
    enum CodingKeys: String, CodingKey {
        case number, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - API payloads

/// Top-level envelope for the GitHub list-jobs API response.
struct JobsPayload: Codable {
    /// Array of decoded job payloads.
    let jobs: [JobPayload]
}

/// Decodable representation of a single job from the GitHub API.
struct JobPayload: Codable {
    /// GitHub job ID.
    let id: Int
    /// Job name.
    let name: String
    /// Current status string.
    let status: String
    /// Conclusion string once completed.
    let conclusion: String?
    /// ISO-8601 start timestamp.
    let startedAt: String?
    /// ISO-8601 creation timestamp.
    let createdAt: String?
    /// ISO-8601 completion timestamp.
    let completedAt: String?
    /// Job page URL.
    let htmlUrl: String
    /// Steps array, present only on single-job detail calls.
    let steps: [JobStep]?

    /// Maps JSON snake_case keys to Swift camelCase properties.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
    }
}

// MARK: - ActiveJob factory

extension RunnerStore {
    /// Builds an `ActiveJob` from a decoded `JobPayload`.
    func makeActiveJob(from payload: JobPayload, iso: ISO8601DateFormatter, isDimmed: Bool) -> ActiveJob {
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

    /// Fetches all currently active jobs for `scope` from the GitHub API.
    func fetchActiveJobs(for scope: String) -> [ActiveJob] {
        let iso = ISO8601DateFormatter()
        guard let data = ghAPI("repos/\(scope)/actions/runs?per_page=20&status=in_progress"),
              let payload = try? JSONDecoder().decode(JobsPayload.self, from: data)
        else { return [] }
        return payload.jobs.map { makeActiveJob(from: $0, iso: iso, isDimmed: false) }
    }

    /// Enriches a job array by overlaying cached step data for completed jobs.
    func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard job.conclusion != nil,
                  let cached = jobCache[job.id],
                  !cached.steps.isEmpty
            else { return job }
            return ActiveJob(
                id: job.id, name: job.name, status: job.status,
                conclusion: job.conclusion, startedAt: job.startedAt,
                createdAt: job.createdAt, completedAt: job.completedAt,
                htmlUrl: job.htmlUrl, isDimmed: job.isDimmed,
                steps: cached.steps
            )
        }
    }
}
