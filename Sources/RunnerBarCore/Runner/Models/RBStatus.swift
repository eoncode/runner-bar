// RBStatus.swift
// RunnerBarCore

// MARK: - RBStatus

/// Semantic display-status values shared across RunnerBarCore and the UI layer.
///
/// Cases are defined here in `RunnerBarCore` so that `ActiveJob.rbStatus` can be
/// computed without importing SwiftUI or AppKit.
/// The `color` property is added via a `RunnerBar`-layer extension in `DesignTokens.swift`.
public enum RBStatus: Sendable {
    /// A job or workflow step that is currently executing.
    case inProgress
    /// A job or workflow step that completed successfully.
    case success
    /// A job or workflow step that failed.
    case failed
    /// A job or workflow step that is waiting to run.
    case queued
    /// An unrecognised or unavailable status.
    case unknown
}
