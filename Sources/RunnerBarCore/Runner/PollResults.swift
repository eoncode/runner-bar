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
    /// Accumulated set of group IDs that have already fired the failure hook.
    ///
    /// Kept separate from `newGroupCache` so that eviction of old display entries
    /// (trimmed at `groupCacheLimit = 30`) does not accidentally re-arm the hook
    /// for groups that were already processed in an earlier poll cycle.
    /// Capped at `PollResultBuilder.seenGroupIDsLimit` entries.
    public let newSeenGroupIDs: Set<String>
}
