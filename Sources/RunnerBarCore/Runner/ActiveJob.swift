// ActiveJob.swift
// RunnerBarCore
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
    ///
    /// - Note: Always `nil` at decode time — scope is not part of the GitHub API job payload.
    ///   `RunnerStore` injects the correct scope by constructing a new `ActiveJob` after fetch.
    ///   Do not attempt to derive scope from runner name or URL here.
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
    // NOSONAR — 12 parameters faithfully model the GitHub API payload.
    /// Creates a new `ActiveJob` with all fields.
    /// - Parameters:
    ///   - id: The unique GitHub job ID.
    ///   - name: The display name of the job.
    ///   - htmlUrl: The GitHub web URL for this job run.
    ///   - status: Typed lifecycle status.
    ///   - conclusion: Typed conclusion (`nil` while running).
    ///   - isDimmed: `true` for cached/history entries. Defaults to `false`.
    ///   - runnerName: The name of the runner executing this job.
    ///   - scope: The repo or org scope string. Injected post-fetch by `RunnerStore`.
    ///   - startedAt: UTC time the job started.
    ///   - completedAt: UTC time the job finished.
    ///   - createdAt: UTC time the job was queued.
    ///   - steps: Ordered step list. Defaults to empty.
    /// - Note: 12 parameters faithfully model the GitHub API payload. // NOSONAR
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
        let isCompleted = status == .completed || conclusion != nil
        return formatElapsed(
            start: startedAt ?? createdAt,
            end: completedAt,
            isCompleted: isCompleted
        )
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

// MARK: - Copy helpers

/// Helpers for deriving immutable `ActiveJob` copies.
extension ActiveJob {
    /// Returns a completed, dimmed copy of this job.
    ///
    /// Centralises the repeated "freeze a job into the cache" pattern in
    /// `PollResultBuilder`: sets `status` to `.completed`, `isDimmed` to `true`,
    /// and fills `completedAt` with `fallbackDate` when the job has no recorded
    /// completion time. All other fields are preserved verbatim.
    ///
    /// When the job has no recorded conclusion (e.g. an API timing race where the
    /// job disappeared before the conclusion field was populated), `.neutral` is
    /// used as the fallback. `.neutral` is the correct "inconclusive" value and
    /// avoids the semantic side-effects of `.cancelled` (hook firing, ⊘ icon).
    /// - Parameter fallbackDate: Date used as `completedAt` when the job has none.
    public func asCompleted(at fallbackDate: Date) -> ActiveJob {
        ActiveJob(
            id: id,
            name: name,
            htmlUrl: htmlUrl,
            status: .completed,
            // .neutral: inconclusive fallback for jobs that vanished before the API
            // populated their conclusion field. Avoids .cancelled side-effects
            // (isHookConclusion=true, conclusionIcon=⊘).
            conclusion: conclusion ?? .neutral,
            isDimmed: true,
            runnerName: runnerName,
            scope: scope,
            startedAt: startedAt,
            completedAt: completedAt ?? fallbackDate,
            createdAt: createdAt,
            steps: steps
        )
    }
}

// MARK: - Job step

/// A single step within an `ActiveJob`.
public struct JobStep: Identifiable, Equatable, Sendable {
    /// Step ID — equals `number` since GitHub steps have no separate stable ID.
    public let id: Int
    /// Display name of the step.
    public let name: String
    /// Typed lifecycle status.
    public let status: JobStatus
    /// Typed conclusion (nil while the step is still running).
    public let conclusion: JobConclusion?
    /// UTC time the step started executing.
    public let startedAt: Date?
    /// UTC time the step finished (nil while running).
    public let completedAt: Date?
    /// 1-based position of this step within its parent job.
    public let number: Int

    /// Creates a new `JobStep`.
    /// - Parameters:
    ///   - id: Step ID (equals `number`).
    ///   - name: Display name of the step.
    ///   - status: Typed lifecycle status.
    ///   - conclusion: Typed conclusion (`nil` while running).
    ///   - startedAt: UTC time the step started.
    ///   - completedAt: UTC time the step finished.
    ///   - number: 1-based position within the parent job. Defaults to `0`.
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
        formatElapsed(
            start: startedAt,
            end: completedAt,
            isCompleted: conclusion != nil
        )
    }

    /// Unicode character summarising the step outcome for display.
    public var conclusionIcon: String {
        switch conclusion {
        case .success: return "\u{2713}"
        case .failure: return "\u{2797}"
        case .skipped, .cancelled: return "\u{2298}"
        default:
            return status == .inProgress ? "\u{25B6}" : "\u{00B7}"
        }
    }
}

// MARK: - API payload (Decodable)

/// Raw API payload decoded from `/actions/runs/{id}/jobs` responses.
///
/// Uses a custom `init(from:)` so that a missing `steps` key decodes as `[]`
/// rather than throwing — the GitHub API omits `steps` for jobs that have not
/// yet started (e.g. queued jobs in a matrix).
public struct JobPayload: Decodable, Sendable {
    /// GitHub job ID.
    public let id: Int
    /// Display name of the job.
    public let name: String
    /// Lifecycle status string as returned by the API.
    public let status: JobStatus
    /// Conclusion string (nil while running).
    public let conclusion: JobConclusion?
    /// ISO 8601 start timestamp string.
    public let startedAt: String?
    /// ISO 8601 completion timestamp string.
    public let completedAt: String?
    /// ISO 8601 creation/queue timestamp string.
    public let createdAt: String?
    /// GitHub web URL for this job run.
    public let htmlUrl: String?
    /// Name of the runner that executed this job.
    public let runnerName: String?
    /// Ordered step payloads (empty for jobs not yet started).
    public let steps: [StepPayload]

    /// Maps Swift property names to the snake_case JSON keys returned by the GitHub API.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `id` JSON field.
        case id
        /// Maps to the `name` JSON field.
        case name
        /// Maps to the `status` JSON field.
        case status
        /// Maps to the `conclusion` JSON field.
        case conclusion
        /// Maps to the `steps` JSON field.
        case steps
        /// Maps to the `started_at` JSON field.
        case startedAt = "started_at"
        /// Maps to the `completed_at` JSON field.
        case completedAt = "completed_at"
        /// Maps to the `created_at` JSON field.
        case createdAt = "created_at"
        /// Maps to the `html_url` JSON field.
        case htmlUrl = "html_url"
        /// Maps to the `runner_name` JSON field.
        case runnerName = "runner_name"
    }

    /// Decodes a `JobPayload` from a JSON container.
    /// Falls back to an empty `steps` array when the key is absent (queued jobs).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(JobStatus.self, forKey: .status)
        conclusion = try container.decodeIfPresent(JobConclusion.self, forKey: .conclusion)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        htmlUrl = try container.decodeIfPresent(String.self, forKey: .htmlUrl)
        runnerName = try container.decodeIfPresent(String.self, forKey: .runnerName)
        steps = try container.decodeIfPresent([StepPayload].self, forKey: .steps) ?? []
    }
}

/// Raw API payload for a single job step.
public struct StepPayload: Decodable, Sendable {
    /// Display name of the step.
    public let name: String
    /// Lifecycle status.
    public let status: JobStatus
    /// Conclusion (nil while running).
    public let conclusion: JobConclusion?
    /// 1-based step number within its parent job.
    public let number: Int
    /// ISO 8601 start timestamp string.
    public let startedAt: String?
    /// ISO 8601 completion timestamp string.
    public let completedAt: String?

    /// Maps Swift property names to the snake_case JSON keys returned by the GitHub API.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `name` JSON field.
        case name
        /// Maps to the `status` JSON field.
        case status
        /// Maps to the `conclusion` JSON field.
        case conclusion
        /// Maps to the `number` JSON field.
        case number
        /// Maps to the `started_at` JSON field.
        case startedAt = "started_at"
        /// Maps to the `completed_at` JSON field.
        case completedAt = "completed_at"
    }
}

/// Wraps the top-level JSON object returned by `/actions/runs/{id}/jobs`.
public struct JobsResponse: Decodable, Sendable {
    /// The list of jobs for this workflow run.
    public let jobs: [JobPayload]
}

// MARK: - Factory

/// Converts a raw `JobPayload` into a fully-typed `ActiveJob`.
///
/// This is the single canonical factory — both `WorkflowActionGroupFetch` and
/// `ISO8601DateParser` delegate here. Do not duplicate this logic elsewhere.
///
/// - Note: `scope` is always set to `nil` here because scope is not present in
///   the GitHub API job payload. Callers in `RunnerStore` inject scope after fetch
///   by constructing a new `ActiveJob` with the correct value.
public func makeActiveJob(
    from payload: JobPayload,
    iso: ISO8601DateFormatter,
    isDimmed: Bool = false
) -> ActiveJob {
    let steps: [JobStep] = payload.steps.map { step in
        JobStep(
            id: step.number,
            name: step.name,
            status: step.status,
            conclusion: step.conclusion,
            startedAt: step.startedAt.flatMap { iso.date(from: $0) },
            completedAt: step.completedAt.flatMap { iso.date(from: $0) },
            number: step.number
        )
    }
    return ActiveJob(
        id: payload.id,
        name: payload.name,
        htmlUrl: payload.htmlUrl,
        status: payload.status,
        conclusion: payload.conclusion,
        isDimmed: isDimmed,
        runnerName: payload.runnerName,
        scope: nil,
        startedAt: payload.startedAt.flatMap { iso.date(from: $0) },
        completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
        createdAt: payload.createdAt.flatMap { iso.date(from: $0) },
        steps: steps
    )
}
