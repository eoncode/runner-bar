// JobStatus.swift
// RunnerBarCore
// swiftlint:disable missing_docs
import Foundation

// MARK: - Job status

/// The lifecycle status of a GitHub Actions job or workflow run.
public enum JobStatus: Hashable, Sendable {
    case queued
    case inProgress
    case completed
    case waiting
    case requested
    case pending
    case unknown(String)

    /// The raw string value as returned by the GitHub API.
    public var rawValue: String {
        switch self {
        case .queued:         return "queued"
        case .inProgress:     return "in_progress"
        case .completed:      return "completed"
        case .waiting:        return "waiting"
        case .requested:      return "requested"
        case .pending:        return "pending"
        case .unknown(let s): return s
        }
    }

    /// Initialise from a raw API string. Unknown values map to `.unknown(raw)`.
    public init(rawString raw: String) {
        switch raw {
        case "queued":       self = .queued
        case "in_progress":  self = .inProgress
        case "completed":    self = .completed
        case "waiting":      self = .waiting
        case "requested":    self = .requested
        case "pending":      self = .pending
        default:             self = .unknown(raw)
        }
    }

    /// Returns `true` when the job / run is still active (not yet completed).
    public var isActive: Bool {
        switch self {
        case .queued, .inProgress, .waiting, .requested, .pending: return true
        case .completed, .unknown: return false
        }
    }
}

extension JobStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawString: raw)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension JobStatus: CustomStringConvertible {
    public var description: String { rawValue }
}

extension JobStatus: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = JobStatus(rawString: value)
    }
}

// MARK: - Job conclusion

/// The outcome of a completed GitHub Actions job or workflow run.
public enum JobConclusion: Hashable, Sendable {
    case success
    case failure
    case cancelled
    case skipped
    case timedOut
    case actionRequired
    case neutral
    case stale
    case startupFailure
    case unknown(String)

    /// The raw string value as returned by the GitHub API.
    public var rawValue: String {
        switch self {
        case .success:            return "success"
        case .failure:            return "failure"
        case .cancelled:          return "cancelled"
        case .skipped:            return "skipped"
        case .timedOut:           return "timed_out"
        case .actionRequired:     return "action_required"
        case .neutral:            return "neutral"
        case .stale:              return "stale"
        case .startupFailure:     return "startup_failure"
        case .unknown(let s):     return s
        }
    }

    /// Initialise from a raw API string. Unknown values map to `.unknown(raw)`.
    public init(rawString raw: String) {
        switch raw {
        case "success":          self = .success
        case "failure":          self = .failure
        case "cancelled":        self = .cancelled
        case "skipped":          self = .skipped
        case "timed_out":        self = .timedOut
        case "action_required":  self = .actionRequired
        case "neutral":          self = .neutral
        case "stale":            self = .stale
        case "startup_failure":  self = .startupFailure
        default:                 self = .unknown(raw)
        }
    }

    /// Returns `true` for terminal failure-like conclusions.
    public var isFailure: Bool {
        switch self {
        case .failure, .timedOut, .startupFailure, .actionRequired: return true
        default: return false
        }
    }
}

extension JobConclusion: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobConclusion(rawString: raw)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension JobConclusion: CustomStringConvertible {
    public var description: String { rawValue }
}

extension JobConclusion: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = JobConclusion(rawString: value)
    }
}
// swiftlint:enable missing_docs
