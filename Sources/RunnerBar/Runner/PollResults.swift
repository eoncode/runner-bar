// PollResults.swift
// RunnerBar
import Foundation

// MARK: - Poll result value types

// Result returned by `PollResultBuilder.buildJobState`.
/// A value type representing JobPollResult.
struct JobPollResult {
    // Jobs to display in the popover (in_progress → queued → cached done).
    /// The display constant.
    let display: [ActiveJob]
    // Updated completed-job cache, trimmed to jobCacheLimit entries.
    /// The newCache constant.
    let newCache: [Int: ActiveJob]
    // Live-job snapshot for the next poll's diff.
    /// The newPrevLive constant.
    let newPrevLive: [Int: ActiveJob]
}

// Result returned by `PollResultBuilder.buildGroupState`.
/// A value type representing GroupPollResult.
struct GroupPollResult {
    // Action groups to display in the popover.
    /// The display constant.
    let display: [WorkflowActionGroup]
    // Updated group cache, trimmed to groupCacheLimit entries.
    /// The newGroupCache constant.
    let newGroupCache: [String: WorkflowActionGroup]
    // Live-group snapshot for the next poll's diff.
    /// The newPrevLiveGroups constant.
    let newPrevLiveGroups: [String: WorkflowActionGroup]
}
