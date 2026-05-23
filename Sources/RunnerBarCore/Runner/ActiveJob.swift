// ActiveJob.swift
// RunnerBarCore
// swiftlint:disable missing_docs
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
    public var isLocalRunner: Bool? {
        guard let name = runnerName?.lowercased() else { return nil }
        let hostedPrefixes = ["ubuntu-", "macos-", "windows-", "buildjet-", "depot-", "github actions "]
        return !hostedPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Display title used in the panel row.
    public var displayTitle: String { name }

    /// Fraction of steps that have a conclusion (0.0–1.0).
    /// Returns `nil` when the step list is empty (jobs not yet enriched).
    public var progressFraction: Double? {
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.conclusion != nil }.count
        return Double(done) / Double(steps.count)
    }
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

    /// A single Unicode character summarising the step's outcome for display in the UI.
    public var conclusionIcon: String {
        switch conclusion {
        case .success:              return "\u{2713}"  // ✓
        case .failure:              return "\u{2797}"  // ❗
        case .skipped, .cancelled:  return "\u{2298}"  // ⊘
        case .none, .some:
            return status == .inProgress ? "\u{25B6}" : "\u{00B7}"
        }
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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case steps
        case startedAt   = "started_at"
        case completedAt = "completed_at"
        case htmlUrl     = "html_url"
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

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case conclusion
        case number
        case startedAt   = "started_at"
        case completedAt = "completed_at"
    }
}

/// Wraps the top-level JSON object returned by `/actions/runs/{id}/jobs`.
public struct JobsResponse: Decodable {
    /// The array of job payloads contained in the response.
    public let jobs: [JobPayload]
}
// swiftlint:enable missing_docs

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
