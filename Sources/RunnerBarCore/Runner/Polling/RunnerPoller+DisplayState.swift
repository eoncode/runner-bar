// RunnerPoller+DisplayState.swift
// RunnerBarCore

// MARK: - RunnerPoller: display state write-through

/// Internal write-through helpers for `RunnerPoller` display state.
extension RunnerPoller {

  // MARK: - Private(set) write-through

  /// Sets the actor-local display properties in a single controlled call.
  ///
  /// **Scope:** this function manages `runners`, `jobs`, `actions`, `isRateLimited`,
  /// and `rateLimitResetDate` only. The five poll-cycle state properties
  /// (`completedCache`, `prevLiveJobs`, `actionGroupCache`, `prevLiveGroups`,
  /// `seenGroupIDs`) are written directly by `applyFetchResult` before calling this
  /// function — they are not routed through `setDisplayState` because they are not
  /// display properties and have no partial-update semantics.
  ///
  /// **Partial-update contract:** `runners`, `jobs`, and `actions` are optional.
  /// Passing `nil` for any of these means “leave the current value unchanged” —
  /// it does **not** clear the list. `isRateLimited` and `rateLimitResetDate` are
  /// non-optional and are **always** updated on every call.
  ///
  /// This asymmetry is intentional: `applyError` calls this function with
  /// `runners/jobs/actions` all `nil` to preserve stale display data during an
  /// error cycle (views continue to show the last known state). Do not call this
  /// function with `nil` display lists intending to clear them — use explicit
  /// empty arrays instead.
  ///
  /// `private(set)` prevents arbitrary writes from outside the actor, but Swift’s
  /// file-scoped `private` means extension files in separate source files cannot
  /// write these properties either. This internal setter is therefore the controlled
  /// mutation path for display properties, used exclusively by `applyFetchResult`
  /// and `applyError` (in `RunnerPoller+ApplyResult.swift`).
  func setDisplayState(
    isRateLimited newIsRateLimited: Bool,
    rateLimitResetDate newResetDate: Date?,
    runners newRunners: [Runner]? = nil,
    jobs newJobs: [ActiveJob]? = nil,
    actions newActions: [WorkflowActionGroup]? = nil
  ) {
    if let newRunners { runners = newRunners }
    if let newJobs { jobs = newJobs }
    if let newActions { actions = newActions }
    isRateLimited = newIsRateLimited
    rateLimitResetDate = newResetDate
  }
}
