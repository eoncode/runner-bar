// ActiveJob.swift
// RunnerBarCore
import Foundation

// MARK: - Top-level job

/// A live or recently-completed GitHub Actions job visible in the panel.
public struct ActiveJob: Identifiable, Equatable {
    // MARK: Identity
    /// The unique GitHub job ID.
    public let id: Int
    /// The display name of the job.
    public let name: String
    /// The GitHub web URL for this job run.
    public let htmlUrl: String?

    // MARK: State
    /// Typed lifecycle status (replaces raw `String`).
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

    // MARK: Steps
    /// The ordered list of steps belonging to this job.
    public let steps: [JobStep]

    // MARK: Derived

    /// Human-readable elapsed duration, e.g. `"02:47"`.
    /// Returns `"--:--"` when `startedAt` is nil.
    public var elapsed: String {
        guard let start = startedAt else { return "--:--" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    /// `true` when this job ran on a self-hosted (non GitHub-hosted) runner.
    public var isLocalRunner: Bool {
        guard let name = runnerName?.lowercased() else { return false }
        let hostedPrefixes = ["ubuntu-", "macos-", "windows-", "buildjet-", "depot-"]
        return !hostedPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Display title used in the panel row.
    public var displayTitle: String { name }
}

// MARK: - Job step

/// A single step within an `ActiveJob`.
public struct JobStep: Identifiable, Equatable {
    /// The step number used as a stable identifier (1-based).
    public let id: Int
    /// The display name of the step.
    public let name: String
    /// Typed lifecycle status of the step.
    public let status: JobStatus
    /// Typed conclusion of the step (nil while the step is still running).
    public let conclusion: JobConclusion?
    /// The UTC date/time at which this step started.
    public let startedAt: Date?
    /// The UTC date/time at which this step finished (nil while running).
    public let completedAt: Date?
    /// The 1-based step number as returned by the API.
    public let number: Int

    /// Human-readable elapsed duration for this step.
    /// Returns `"--:--"` when `startedAt` is nil.
    public var elapsed: String {
        guard let start = startedAt else { return "--:--" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - API payload (Decodable)

/// Raw API payload decoded from `/actions/runs/{id}/jobs` responses.
/// Converted to `ActiveJob` via `makeActiveJob(from:iso:isDimmed:)`.
public struct JobPayload: Decodable {
    /// The unique GitHub job ID.
    public let id: Int
    /// The display name of the job.
    public let name: String
    /// Typed lifecycle status decoded from JSON.
    public let status: JobStatus
    /// Typed conclusion decoded from JSON (nil while the job is running).
    public let conclusion: JobConclusion?
    /// ISO-8601 start timestamp string as returned by the API.
    public let startedAt: String?
    /// ISO-8601 completion timestamp string as returned by the API.
    public let completedAt: String?
    /// The GitHub web URL for this job.
    public let htmlUrl: String?
    /// The name of the runner that executed or is executing this job.
    public let runnerName: String?
    /// The steps belonging to this job.
    public let steps: [StepPayload]

    /// JSON coding keys for `JobPayload`.
    enum CodingKeys: String, CodingKey {
        /// Maps to `id`.
        case id
        /// Maps to `name`.
        case name
        /// Maps to `status`.
        case status
        /// Maps to `conclusion`.
        case conclusion
        /// Maps to `steps`.
        case steps
        /// Maps to `started_at`.
        case startedAt   = "started_at"
        /// Maps to `completed_at`.
        case completedAt = "completed_at"
        /// Maps to `html_url`.
        case htmlUrl     = "html_url"
        /// Maps to `runner_name`.
        case runnerName  = "runner_name"
    }
}

/// Raw API payload for a single job step, decoded from the `steps` array in a jobs response.
public struct StepPayload: Decodable {
    /// The display name of the step.
    public let name: String
    /// Typed lifecycle status of the step.
    public let status: JobStatus
    /// Typed conclusion of the step (nil while the step is running).
    public let conclusion: JobConclusion?
    /// The 1-based step number.
    public let number: Int
    /// ISO-8601 start timestamp string as returned by the API.
    public let startedAt: String?
    /// ISO-8601 completion timestamp string as returned by the API.
    public let completedAt: String?

    /// JSON coding keys for `StepPayload`.
    enum CodingKeys: String, CodingKey {
        /// Maps to `name`.
        case name
        /// Maps to `status`.
        case status
        /// Maps to `conclusion`.
        case conclusion
        /// Maps to `number`.
        case number
        /// Maps to `started_at`.
        case startedAt   = "started_at"
        /// Maps to `completed_at`.
        case completedAt = "completed_at"
    }
}

/// Wraps the top-level JSON object returned by `/actions/runs/{id}/jobs`.
public struct JobsResponse: Decodable {
    /// The array of job payloads contained in the response.
    public let jobs: [JobPayload]
}

// MARK: - Factory

/// Converts a raw `JobPayload` into a fully-typed `ActiveJob`.
///
/// - Parameters:
///   - payload: The decoded API payload.
///   - iso: A shared `ISO8601DateFormatter` instance (expensive to allocate — pass a cached one).
///   - isDimmed: Pass `true` for recently-completed jobs shown as faded history entries.
/// - Returns: A fully-populated `ActiveJob`.
public func makeActiveJob(
    from payload: JobPayload,
    iso: ISO8601DateFormatter,
    isDimmed: Bool
) -> ActiveJob {
    let steps: [JobStep] = payload.steps.map { s in
        JobStep(
            id:          s.number,
            name:        s.name,
            status:      s.status,
            conclusion:  s.conclusion,
            startedAt:   s.startedAt.flatMap  { iso.date(from: $0) },
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
        startedAt:   payload.startedAt.flatMap  { iso.date(from: $0) },
        completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
        steps:       steps
    )
}
