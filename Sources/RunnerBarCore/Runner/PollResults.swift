// PollResults.swift
// RunnerBarCore
import Foundation

// MARK: - Poll result value types

/// Result returned by `PollResultBuilder.buildJobState`.
public struct JobPollResult: Sendable {
    /// Jobs to display in the popover (in_progress → queued → cached done).
    public let display: [ActiveJob]
    /// Updated completed-job cache, trimmed to `PollResultBuilder.jobCacheLimit` entries.
    public let newCache: [Int: ActiveJob]
    /// Live-job snapshot for the next poll's diff.
    public let newPrevLive: [Int: ActiveJob]

    /// Creates a `JobPollResult` with all fields.
    /// - Parameters:
    ///   - display: Jobs to show in the popover.
    ///   - newCache: Updated completed-job cache.
    ///   - newPrevLive: Live-job snapshot for the next poll's diff.
    public init(display: [ActiveJob], newCache: [Int: ActiveJob], newPrevLive: [Int: ActiveJob]) {
        self.display = display
        self.newCache = newCache
        self.newPrevLive = newPrevLive
    }
}

/// Result returned by `PollResultBuilder.buildGroupState`.
public struct GroupPollResult: Sendable {
    /// Action groups to display in the popover.
    public let display: [WorkflowActionGroup]
    /// Updated group cache, trimmed to `PollResultBuilder.groupCacheLimit` entries.
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

    /// Creates a `GroupPollResult` with all fields.
    /// - Parameters:
    ///   - display: Groups to show in the popover.
    ///   - newGroupCache: Updated group cache.
    ///   - newPrevLiveGroups: Live-group snapshot for the next poll's diff.
    ///   - newSeenGroupIDs: Accumulated set of seen group IDs.
    public init(
        display: [WorkflowActionGroup],
        newGroupCache: [String: WorkflowActionGroup],
        newPrevLiveGroups: [String: WorkflowActionGroup],
        newSeenGroupIDs: Set<String>
    ) {
        self.display = display
        self.newGroupCache = newGroupCache
        self.newPrevLiveGroups = newPrevLiveGroups
        self.newSeenGroupIDs = newSeenGroupIDs
    }
}
