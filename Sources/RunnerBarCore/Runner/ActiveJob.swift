// ActiveJob.swift
// RunnerBarCore
// swiftlint:disable missing_docs
import Foundation

// MARK: - Top-level job

/// A live or recently-completed GitHub Actions job visible in the panel.
public struct ActiveJob: Identifiable, Equatable, Sendable {
    // MARK: Identity
    /// The unique GitHub job ID.
    public let id: Int
    /// The display name of the job.
    public let name: String
    /// The GitHub web URL for this job run.
    public let htmlUrl: String?

    // MARK: State
    /// Typed lifecycle status.
    public let status: JobStatus
    /// Typed conclusion (nil while the job is still running).
    public let conclusion: JobConclusion?
    /// `true` for recently-completed jobs shown as faded history entries.
    public var isDimmed: Bool

    // MARK: Runner / scope
    /// The name of the runner that executed (or is executing) this job.
    public let runnerName: String?
    /// The repo or org scope string this job belongs to.
    public let scope: String?

    // MARK: Timing
    /// The UTC date/time at which the job started executing.
    public let startedAt: Date?
    /// The UTC date/time at which the job finished (nil while running).
    public let completedAt: Date?
    /// The UTC date/time at which the job was created/queued.
    public let createdAt: Date?

    // MARK: Steps
    /// The ordered list of steps belonging to this job.
    public let steps: [JobStep]

    // MARK: Designated init
    public init(
        id: Int,
        name: String,
        htmlUrl: String? = nil,
        status: JobStatus,
        conclusion: JobConclusion? = nil,
        isDimmed: Bool = false,
        runnerName: String? = nil,
        scope: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        steps: [JobStep] = []
    ) {
        self.id = id
        self.name = name
        self.htmlUrl = htmlUrl
        self.status = status
        self.conclusion = conclusion
        self.isDimmed = isDimmed
        self.runnerName = runnerName
        self.scope = scope
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.steps = steps
    }

    // MARK: Derived

    /// Human-readable elapsed duration, e.g. `"02:47"`.
    /// - Returns `"--:--"` for completed jobs where both `startedAt` and `createdAt` are nil
    ///   (timing data unavailable from API).
    /// - Returns `"00:00"` for queued/in-progress jobs with no timing yet.
    /// - Uses `startedAt` if available, falls back to `createdAt`.
    public var elapsed: String {
        let start = startedAt ?? createdAt
        guard let start else {
            // #781: completed jobs with no timing data show dashes, not a fake zero.
            return (status == .completed || conclusion != nil) ? "--:--" : "00:00"
        }
        let end = completedAt ?? Date()
        // Clamp to ≥0 to guard against API clock skew (completedAt < startedAt).
        let secs = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    /// `true` when this job ran on a self-hosted runner; `nil` when runner name is unknown.
    public var isLocalRunner: Bool? {
        guard let name = runnerName?.lowercased() else { return nil }
        let hostedPrefixes = ["ubuntu-", "macos-", "windows-", "buildjet-", "depot-", "github actions "]
        return !hostedPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Display title used in the panel row.
    public var displayTitle: String { name }

    /// Fraction of steps that have a conclusion (0.0–1.0). `nil` when step list is empty.
    public var progressFraction: Double? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.conclusion != nil }.count
        return Double(done) / Double(steps.count)
    }
}

// MARK: - Job step

/// A single step within an `ActiveJob`.
public struct JobStep: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let status: JobStatus
    public let conclusion: JobConclusion?
    public let startedAt: Date?
    public let completedAt: Date?
    public let number: Int

    public init(
        id: Int,
        name: String,
        status: JobStatus,
        conclusion: JobConclusion? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        number: Int = 0
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.number = number
    }

    /// Human-readable elapsed duration.
    /// - Returns `"--:--"` for completed steps where `startedAt` is nil (timing unavailable).
    /// - Returns `"00:00"` for in-progress or queued steps with no timing yet.
    public var elapsed: String {
        guard let start = startedAt else {
            // #781: completed steps with no timing data show dashes, not a fake zero.
            return (conclusion != nil) ? "--:--" : "00:00"
        }
        let end = completedAt ?? Date()
        // Clamp to ≥0 to guard against API clock skew (completedAt < startedAt).
        let secs = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    /// Unicode character summarising the step outcome for display.
    public var conclusionIcon: String {
        switch conclusion {
        case .success:              return "\u{2713}"
        case .failure:              return "\u{2797}"
        case .skipped, .cancelled:  return "\u{2298}"
        default:
            return status == .inProgress ? "\u{25B6}" : "\u{00B7}"
        }
    }
}

// MARK: - API payload (Decodable)

/// Raw API payload decoded from `/actions/runs/{id}/jobs` responses.
/// Uses a custom `init(from:)` so that a missing `steps` key decodes as `[]`
/// rather than throwing — the GitHub API omits `steps` for jobs that have not
/// yet started (e.g. queued jobs in a matrix).
public struct JobPayload: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let status: JobStatus
    public let conclusion: JobConclusion?
    public let startedAt: String?
    public let completedAt: String?
    public let createdAt: String?
    public let htmlUrl: String?
    public let runnerName: String?
    public let steps: [StepPayload]

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt   = "started_at"
        case completedAt = "completed_at"
        case createdAt   = "created_at"
        case htmlUrl     = "html_url"
        case runnerName  = "runner_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(Int.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        status      = try c.decode(JobStatus.self, forKey: .status)
        conclusion  = try c.decodeIfPresent(JobConclusion.self, forKey: .conclusion)
        startedAt   = try c.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt   = try c.decodeIfPresent(String.self, forKey: .createdAt)
        htmlUrl     = try c.decodeIfPresent(String.self, forKey: .htmlUrl)
        runnerName  = try c.decodeIfPresent(String.self, forKey: .runnerName)
        steps       = try c.decodeIfPresent([StepPayload].self, forKey: .steps) ?? []
    }
}

/// Raw API payload for a single job step.
public struct StepPayload: Decodable, Sendable {
    public let name: String
    public let status: JobStatus
    public let conclusion: JobConclusion?
    public let number: Int
    public let startedAt: String?
    public let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, number
        case startedAt   = "started_at"
        case completedAt = "completed_at"
    }
}

/// Wraps the top-level JSON object returned by `/actions/runs/{id}/jobs`.
public struct JobsResponse: Decodable, Sendable {
    public let jobs: [JobPayload]
}
// swiftlint:enable missing_docs

// MARK: - Factory

/// Converts a raw `JobPayload` into a fully-typed `ActiveJob`.
/// This is the single canonical factory — both `WorkflowActionGroupFetch` and
/// `GitHub.swift` delegate here. Do not duplicate this logic elsewhere.
public func makeActiveJob(
    from payload: JobPayload,
    iso: ISO8601DateFormatter,
    isDimmed: Bool = false
) -> ActiveJob {
    let steps: [JobStep] = payload.steps.map { s in
        JobStep(
            id:          s.number,
            name:        s.name,
            status:      s.status,
            conclusion:  s.conclusion,
            startedAt:   s.startedAt.flatMap { iso.date(from: $0) },
            completedAt: s.completedAt.flatMap { iso.date(from: $0) },
            number:      s.number
        )
    }
    return ActiveJob(
        id:          payload.id,
        name:        payload.name,
        htmlUrl:     payload.htmlUrl,
        status:      payload.status,
        conclusion:  payload.conclusion,
        isDimmed:    isDimmed,
        runnerName:  payload.runnerName,
        scope:       nil,
        startedAt:   payload.startedAt.flatMap { iso.date(from: $0) },
        completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
        createdAt:   payload.createdAt.flatMap { iso.date(from: $0) },
        steps:       steps
    )
}
