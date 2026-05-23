// PollResults.swift
// RunnerBar
import Foundation

// MARK: - Poll result value types

/// Result returned by `PollResultBuilder.buildJobState`.
public struct JobPollResult {
    /// Jobs to display in the popover (in_progress → queued → cached done).
    public let display: [ActiveJob]
    /// Updated completed-job cache, trimmed to jobCacheLimit entries.
    public let newCache: [Int: ActiveJob]
    /// Live-job snapshot for the next poll's diff.
    public let newPrevLive: [Int: ActiveJob]
}

/// Result returned by `PollResultBuilder.buildGroupState`.
public struct GroupPollResult {
    /// Action groups to display in the popover.
    public let display: [WorkflowActionGroup]
    /// Updated group cache, trimmed to groupCacheLimit entries.
    public let newGroupCache: [String: WorkflowActionGroup]
    /// Live-group snapshot for the next poll's diff.
    public let newPrevLiveGroups: [String: WorkflowActionGroup]
}
