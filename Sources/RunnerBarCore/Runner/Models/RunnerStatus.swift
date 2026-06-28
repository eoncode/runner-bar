// RunnerStatus.swift
// RunBotCore
//
// Typed representation of the GitHub API runner status field.
// Replaces the raw String used in Runner and RunnerModel.
// See: Runner, RunnerModel, RunnerStatusEnricher

// MARK: - RunnerStatus

/// The connectivity status of a GitHub Actions runner as reported by the GitHub API.
///
/// Replaces the raw `String` previously stored in `Runner.status` and
/// `RunnerModel.githubStatus`. Using an enum makes all call sites exhaustive
/// and prevents silent fallthrough when GitHub introduces new status values.
///
/// - SeeAlso: `Runner`, `RunnerModel`, `RunnerStatusEnricher`
public enum RunnerStatus: Hashable, Sendable {
    /// Runner is connected and accepting jobs.
    case online
    /// Runner is connected and currently executing a job.
    case busy
    /// Runner is not connected to GitHub.
    case offline
    /// A status value not recognised at compile time.
    ///
    /// - Note: Acts as a forward-compatible fallback so new GitHub API status
    ///   values do not cause a decode failure or silent data loss.
    case unknown(String)

    /// Initialises from the raw API string. Unrecognised values map to `.unknown(raw)`.
    ///
    /// - Parameter raw: The raw string value as returned by the GitHub REST API.
    public init(rawString raw: String) {
        switch raw {
        case "online": self = .online
        case "busy": self = .busy
        case "offline": self = .offline
        default: self = .unknown(raw)
        }
    }

    /// The raw string value as returned by the GitHub API.
    public var rawValue: String {
        switch self {
        case .online: return "online"
        case .busy: return "busy"
        case .offline: return "offline"
        case .unknown(let raw): return raw
        }
    }
}

/// `Codable` conformance for `RunnerStatus` — encodes and decodes as a plain string.
extension RunnerStatus: Codable {
    /// Decodes from a single-value string container.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunnerStatus(rawString: raw)
    }

    /// Encodes as a single-value string container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `CustomStringConvertible` conformance for `RunnerStatus`.
extension RunnerStatus: CustomStringConvertible {
    /// Returns the raw API string value.
    public var description: String { rawValue }
}
