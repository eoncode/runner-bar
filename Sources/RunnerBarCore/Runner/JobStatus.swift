// JobStatus.swift
// RunnerBarCore
import Foundation

// MARK: - Job status

/// The lifecycle status of a GitHub Actions job or workflow run.
///
/// Uses a custom `Decodable` initialiser with an `.unknown` fallback so that
/// new GitHub API status values never cause a decode failure.
public enum JobStatus: Hashable {
    /// Job is waiting to be picked up by a runner.
    case queued
    /// Job is currently executing on a runner.
    case inProgress
    /// Job has finished (see `JobConclusion` for the outcome).
    case completed
    /// Job is waiting on a required deployment environment approval.
    case waiting
    /// Job has been requested but not yet queued.
    case requested
    /// Job is pending initial scheduling.
    case pending
    /// Any status string not matched by the cases above (forward-compatibility).
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

    /// Returns `true` when the job / run is still active (not yet completed).
    public var isActive: Bool {
        switch self {
        case .queued, .inProgress, .waiting, .requested, .pending: return true
        case .completed, .unknown: return false
        }
    }
}

extension JobStatus: Codable {
    /// Creates a `JobStatus` by decoding a single raw string value.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
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

    /// Encodes the receiver as its raw string value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension JobStatus: CustomStringConvertible {
    /// A human-readable description equal to `rawValue`.
    public var description: String { rawValue }
}

// MARK: - Job conclusion

/// The outcome of a completed GitHub Actions job or workflow run.
///
/// Uses a custom `Decodable` initialiser with an `.unknown` fallback so that
/// new GitHub API conclusion values never cause a decode failure.
public enum JobConclusion: Hashable {
    /// Job completed successfully.
    case success
    /// Job completed with a failure.
    case failure
    /// Job was cancelled before completion.
    case cancelled
    /// Job was skipped (e.g. due to an `if:` condition).
    case skipped
    /// Job exceeded its timeout limit.
    case timedOut
    /// Job requires manual approval to proceed.
    case actionRequired
    /// Job completed with a neutral outcome (no pass/fail signal).
    case neutral
    /// Job result is stale and no longer relevant.
    case stale
    /// Job failed to start up before executing any steps.
    case startupFailure
    /// Any conclusion string not matched by the cases above (forward-compatibility).
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

    /// Returns `true` for terminal failure-like conclusions.
    public var isFailure: Bool {
        switch self {
        case .failure, .timedOut, .startupFailure, .actionRequired: return true
        default: return false
        }
    }
}

extension JobConclusion: Codable {
    /// Creates a `JobConclusion` by decoding a single raw string value.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
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

    /// Encodes the receiver as its raw string value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension JobConclusion: CustomStringConvertible {
    /// A human-readable description equal to `rawValue`.
    public var description: String { rawValue }
}
