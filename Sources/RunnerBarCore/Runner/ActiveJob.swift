// ActiveJob.swift
// RunnerBar
// swiftlint:disable identifier_name opening_brace colon function_parameter_count
import Foundation

// MARK: - ActiveJob model

/// Represents a single GitHub Actions job that is live or recently completed.
public struct ActiveJob: Identifiable, Codable, Equatable, Sendable {
    /// GitHub-assigned job identifier.
    public let id: Int
    /// Display name of the job.
    public let name: String
    /// Current lifecycle status (`queued`, `in_progress`, `completed`).
    public let status: String
    /// Final outcome once the job finishes (`success`, `failure`, `cancelled`, etc.).
    public let conclusion: String?
    /// When the job runner picked up the job.
    public let startedAt: Date?
    /// When the job was added to the queue.
    public let createdAt: Date?
    /// When the job finished.
    public let completedAt: Date?
    /// Deep-link URL on github.com for this job.
    public let htmlUrl: String?
    /// `true` when the job is shown as a dimmed historical entry.
    public let isDimmed: Bool
    /// Ordered list of steps within this job.
    public let steps: [JobStep]
    /// Name of the runner that picked up this job.
    /// `nil` when the job is still queued and hasn't been assigned yet.
    /// Used to determine local vs cloud icon on action rows.
    public let runnerName: String?

    /// Human-readable elapsed wall-clock string for this job in `MM:SS` format.
    ///
    /// - Queued jobs always return `"00:00"` (no time has elapsed yet).
    /// - Completed jobs return `"--:--"` when both `startedAt` and `completedAt`
    ///   are unavailable, otherwise the fixed duration.
    /// - Live (`in_progress`) jobs use `startedAt` if available, falling back to
    ///   `createdAt` while the runner assignment is still pending, and measures
    ///   up to `Date()` (wall clock).
    public var elapsed: String {
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

    /// `true` if this job ran (or is running) on a self-hosted local runner.
    ///
    /// Returns `nil` when `runnerName` is not yet known (job still queued and
    /// unassigned). Returns `false` for well-known GitHub-hosted runner name
    /// prefixes (`ubuntu-`, `macos-`, `windows-`, etc.).
    public var isLocalRunner: Bool? {
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

    /// Creates a new instance.
    public init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: Date? = nil,
        createdAt: Date? = nil,
        completedAt: Date? = nil,
        htmlUrl: String? = nil,
        isDimmed: Bool = false,
        steps: [JobStep] = [],
        runnerName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.htmlUrl = htmlUrl
        self.isDimmed = isDimmed
        self.steps = steps
        self.runnerName = runnerName
    }

    // MARK: Codable
    /// UserDefaults key constants.
    enum CodingKeys: String, CodingKey {
        /// The `id` case.
        case id, name, status, conclusion
        /// Coding key for the `startedAt` field.
        case startedAt = "started_at"
        /// Coding key for the `createdAt` field.
        case createdAt = "created_at"
        /// Coding key for the `completedAt` field.
        case completedAt = "completed_at"
        /// Coding key for the `htmlUrl` field.
        case htmlUrl = "html_url"
        /// The `isDimmed` case.
        case isDimmed
        /// The `steps` case.
        case steps
        /// Coding key for the `runnerName` field.
        case runnerName = "runner_name"
    }
}

// MARK: - JobStep

/// A single step within an `ActiveJob`, matching the GitHub API `steps` array.
public struct JobStep: Identifiable, Codable, Equatable, Sendable {
    /// Step sequence number (1-based).
    public let id: Int
    /// Display name of the step.
    public let name: String
    /// Lifecycle status of the step.
    public let status: String
    /// Conclusion of the step once finished.
    public let conclusion: String?
    /// When this step started.
    public let startedAt: Date?
    /// When this step finished.
    public let completedAt: Date?

    /// A single Unicode character summarising the step's outcome for display in the UI.
    public var conclusionIcon: String {
        switch conclusion {
        case "success": return "\u{2713}"
        case "failure": return "\u{2797}"
        case "skipped": return "\u{2298}"
        case "cancelled": return "\u{2298}"
        default: return status == "in_progress" ? "\u{25B6}" : "\u{00B7}"
        }
    }

    /// Human-readable elapsed duration for this step in `MM:SS` format.
    public var elapsed: String {
        let start = startedAt ?? Date()
        let end = completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        guard secs >= 0 else { return "00:00" }
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Creates a new instance.
    public init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// UserDefaults key constants.
    enum CodingKeys: String, CodingKey {
        /// Coding key for the `id` field.
        case id = "number"
        /// The `name` case.
        case name, status, conclusion
        /// Coding key for the `startedAt` field.
        case startedAt = "started_at"
        /// Coding key for the `completedAt` field.
        case completedAt = "completed_at"
    }
}

// MARK: - JobPayload (API decoding)

/// Raw Decodable mirror of the GitHub Actions jobs API response object.
public struct JobPayload: Decodable {
    /// The id constant.
    public let id: Int
    /// The name constant.
    public let name: String
    /// The status constant.
    public let status: String
    /// The conclusion constant.
    public let conclusion: String?
    /// The startedAt constant.
    public let startedAt: String?
    /// The createdAt constant.
    public let createdAt: String?
    /// The completedAt constant.
    public let completedAt: String?
    /// The htmlUrl constant.
    public let htmlUrl: String?
    /// The steps constant.
    public let steps: [StepPayload]?
    /// The runnerName constant.
    public let runnerName: String?

    /// UserDefaults key constants.
    enum CodingKeys: String, CodingKey {
        /// The `id` case.
        case id, name, status, conclusion, steps
        /// Coding key for the `startedAt` field.
        case startedAt = "started_at"
        /// Coding key for the `createdAt` field.
        case createdAt = "created_at"
        /// Coding key for the `completedAt` field.
        case completedAt = "completed_at"
        /// Coding key for the `htmlUrl` field.
        case htmlUrl = "html_url"
        /// Coding key for the `runnerName` field.
        case runnerName = "runner_name"
    }
}

// MARK: - StepPayload (API decoding)

/// Raw Decodable mirror of a single step entry within a `JobPayload`.
public struct StepPayload: Decodable {
    /// The number constant.
    public let number: Int
    /// The name constant.
    public let name: String
    /// The status constant.
    public let status: String
    /// The conclusion constant.
    public let conclusion: String?
    /// The startedAt constant.
    public let startedAt: String?
    /// The completedAt constant.
    public let completedAt: String?

    /// UserDefaults key constants.
    enum CodingKeys: String, CodingKey {
        /// The `number` case.
        case number, name, status, conclusion
        /// Coding key for the `startedAt` field.
        case startedAt = "started_at"
        /// Coding key for the `completedAt` field.
        case completedAt = "completed_at"
    }
}

// MARK: - Codable helpers

/// A value type representing JobsResponse.
public struct JobsResponse: Decodable {
    /// The `jobs` property.
    public let jobs: [JobPayload]
}
// swiftlint:enable identifier_name opening_brace colon function_parameter_count
