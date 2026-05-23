// ActiveJob.swift
// RunnerBarCore
import Foundation

// MARK: - Top-level job

/// A live or recently-completed GitHub Actions job visible in the panel.
public struct ActiveJob: Identifiable, Equatable {
    // MARK: Identity
    /// The `id` property.
    public let id: Int
    /// The `name` property.
    public let name: String
    /// The `htmlUrl` property.
    public let htmlUrl: String?

    // MARK: State
    /// Typed lifecycle status (replaces raw `String`).
    public let status: JobStatus
    /// Typed conclusion (nil while the job is still running).
    public let conclusion: JobConclusion?
    /// The `isDimmed` property — true for recently-completed jobs shown as faded history.
    public var isDimmed: Bool

    // MARK: Runner / scope
    /// The `runnerName` property.
    public let runnerName: String?
    /// The `scope` property.
    public let scope: String?

    // MARK: Timing
    /// The `startedAt` property.
    public let startedAt: Date?
    /// The `completedAt` property.
    public let completedAt: Date?

    // MARK: Steps
    /// The `steps` property.
    public let steps: [JobStep]

    // MARK: Derived

    /// Human-readable elapsed duration, e.g. `"02:47"`.
    public var elapsed: String {
        guard let start = startedAt else { return "--:--" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    /// `true` when this job ran on a GitHub-hosted (non-self-hosted) runner.
    public var isLocalRunner: Bool {
        guard let name = runnerName?.lowercased() else { return false }
        let hostedPrefixes = ["ubuntu-", "macos-", "windows-", "buildjet-", "depot-"]
        return !hostedPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Display title used in the panel row.
    public var displayTitle: String { name }
}

// MARK: - Job step

/// A single step within a `ActiveJob`.
public struct JobStep: Identifiable, Equatable {
    /// The `id` property (step number, 1-based).
    public let id: Int
    /// The `name` property.
    public let name: String
    /// Typed lifecycle status.
    public let status: JobStatus
    /// Typed conclusion (nil while the step is still running).
    public let conclusion: JobConclusion?
    /// The `startedAt` property.
    public let startedAt: Date?
    /// The `completedAt` property.
    public let completedAt: Date?
    /// The `number` property (1-based step number from the API).
    public let number: Int

    /// Human-readable elapsed duration for this step.
    public var elapsed: String {
        guard let start = startedAt else { return "--:--" }
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - API payload (Decodable)

/// Raw API payload decoded from `/actions/jobs/{id}` responses.
/// Converted to `ActiveJob` via `makeActiveJob(from:iso:isDimmed:)`.
public struct JobPayload: Decodable {
    /// The `id` property.
    public let id: Int
    /// The `name` property.
    public let name: String
    /// Typed lifecycle status decoded from JSON.
    public let status: JobStatus
    /// Typed conclusion decoded from JSON (optional — nil while running).
    public let conclusion: JobConclusion?
    /// The `startedAt` property.
    public let startedAt: String?
    /// The `completedAt` property.
    public let completedAt: String?
    /// The `htmlUrl` property.
    public let htmlUrl: String?
    /// The `runnerName` property.
    public let runnerName: String?
    /// The `steps` property.
    public let steps: [StepPayload]

    /// JSON coding keys for `JobPayload`.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt  = "started_at"
        case completedAt = "completed_at"
        case htmlUrl    = "html_url"
        case runnerName = "runner_name"
    }
}

/// Raw API payload for a single job step.
public struct StepPayload: Decodable {
    /// The `name` property.
    public let name: String
    /// Typed lifecycle status decoded from JSON.
    public let status: JobStatus
    /// Typed conclusion decoded from JSON (optional).
    public let conclusion: JobConclusion?
    /// The `number` property.
    public let number: Int
    /// The `startedAt` property.
    public let startedAt: String?
    /// The `completedAt` property.
    public let completedAt: String?

    /// JSON coding keys for `StepPayload`.
    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, number
        case startedAt   = "started_at"
        case completedAt = "completed_at"
    }
}

/// Wraps a `/actions/runs/{id}/jobs` API response.
public struct JobsResponse: Decodable {
    /// The `jobs` property.
    public let jobs: [JobPayload]
}

// MARK: - Factory

/// Converts a raw `JobPayload` + `StepPayload` array into a fully-typed `ActiveJob`.
public func makeActiveJob(
    from payload: JobPayload,
    iso: ISO8601DateFormatter,
    isDimmed: Bool
) -> ActiveJob {
    let steps: [JobStep] = payload.steps.map { s in
        JobStep(
            id: s.number,
            name: s.name,
            status: s.status,
            conclusion: s.conclusion,
            startedAt:   s.startedAt.flatMap { iso.date(from: $0) },
            completedAt: s.completedAt.flatMap { iso.date(from: $0) },
            number: s.number
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
