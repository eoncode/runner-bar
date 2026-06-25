// PollResultBuilder.swift
// RunnerBarCore
import Collections
import OrderedCollections
import Foundation

// MARK: - PollResultBuilder

/// Pure state-building logic extracted from RunnerStore.
///
/// All methods are static and operate only on data passed as parameters.
/// Fetch / API side-effects are injected as closures so this type is
/// independently unit-testable without a RunnerStore instance.
public struct PollResultBuilder {

    // MARK: - Cache limits

    /// Maximum number of completed jobs retained in the job cache.
    public static let jobCacheLimit = 3

    /// Maximum number of job entries shown in the panel UI (live + cached combined).
    ///
    /// Intentionally larger than `jobCacheLimit` so that live in-progress and queued
    /// jobs are never silently dropped when the cache is already full.
    /// `jobCacheLimit` controls *retention*; `jobDisplayLimit` controls *visibility*.
    public static let jobDisplayLimit = 10

    /// Maximum number of completed groups retained in the group cache.
    public static let groupCacheLimit = 30

    /// Maximum number of groups shown in the panel UI (live + cached combined).
    ///
    /// Analogous to `jobDisplayLimit` — separates *retention* from *visibility*.
    /// Prevents the panel flooding with up to `groupCacheLimit` (30) stale entries.
    public static let groupDisplayLimit = 10

    /// Maximum number of group IDs retained in the seen-IDs set.
    ///
    /// Kept much larger than `groupCacheLimit` so that the failure-hook suppression
    /// set survives well beyond the display-cache eviction horizon.
    /// Sized for ~6–7 poll cycles worth of typical group completions at once.
    /// Entries are pruned FIFO (oldest-first) when the limit is exceeded.
    public static let seenGroupIDsLimit = 200

    // MARK: - Job state

    /// Builds the job display list and updated caches from a background poll snapshot.
    ///
    /// - Parameters:
    ///   - snapPrev: Live-job snapshot from the previous poll.
    ///   - snapCache: Completed-job cache from the previous poll.
    ///   - fetchJobs: Async closure that fetches live jobs for every active scope.
    ///   - backfill: Async closure that backfills step data into a completed-job cache entry.
    public static func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob],
        fetchJobs: @Sendable () async -> [ActiveJob],
        backfill: @Sendable (inout [Int: ActiveJob]) async -> Void
    ) async -> JobPollResult {
        let allFetched: [ActiveJob] = await fetchJobs()
        let liveJobs: [ActiveJob] = allFetched.filter { $0.conclusion == nil && $0.status != .completed }
        let freshDone: [ActiveJob] = allFetched.filter { $0.conclusion != nil || $0.status == .completed }
        let liveIDs: Set<Int> = Set(liveJobs.map { $0.id })
        let now = Date()
        var newCache: [Int: ActiveJob] = snapCache
        applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
        for job in freshDone {
            newCache[job.id] = job.asCompleted(at: now)
        }
        trimJobCache(&newCache, limit: jobCacheLimit)
        await backfill(&newCache)
        let newPrevLive: [Int: ActiveJob] = [Int: ActiveJob](uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
        let display = buildJobDisplay(live: liveJobs, cache: newCache)
        let inProgCount = liveJobs.filter { $0.status == .inProgress }.count
        let queuedCount = liveJobs.filter { $0.status == .queued }.count
        log(
            "PollResultBuilder › \(inProgCount) in_progress \(queuedCount) queued"
                + " | cache: \(newCache.count) | display: \(display.count)"
        )
        return JobPollResult(display: display, newCache: newCache, newPrevLive: newPrevLive)
    }

    // MARK: - Group state

    /// Builds the action-group display list and updated caches from a background poll.
    ///
    /// - Parameters:
    ///   - snapPrevGroups: Live-group snapshot from the previous poll.
    ///   - snapGroupCache: Completed-group cache from the previous poll.
    ///   - snapSeenGroupIDs: OrderedSet of group IDs that have already triggered the failure
    ///     hook in a previous poll cycle. Contains `WorkflowActionGroup.id` values.
    ///     Survives `trimGroupCache` eviction so the hook cannot re-fire for old groups.
    ///     Insertion order is preserved so `trimSeenGroupIDs` evicts the oldest entries first.
    ///   - fetchGroups: Async closure that fetches live groups for every active scope.
    ///   - scopeFromGroup: Synchronous closure that derives a scope string from a WorkflowActionGroup.
    ///   - fireFailureHook: Async closure invoked the first time a group transitions to a hook-triggering conclusion.
    ///   - enrichJobs: Async closure that enriches a job list from the job cache.
    ///
    /// - Important: `doneGroups` inserts into `newSeenGroupIDs` **before**
    ///   `freezeVanishedGroups` runs, so a group that appears in both the fetched
    ///   completed list and in `snapPrevGroups` fires the hook exactly once.
    ///   Enrichment is split into two sequential sweeps — see inline comments for rationale.
    public static func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        snapSeenGroupIDs: OrderedSet<String> = [],
        fetchGroups: @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup],
        scopeFromGroup: @Sendable (WorkflowActionGroup) -> String,
        fireFailureHook: @Sendable (WorkflowActionGroup, String) async -> Void,
        enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
    ) async -> GroupPollResult {
        log("PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count) snapSeenGroupIDs=\(snapSeenGroupIDs.count)")
        let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
        let allFetched = await fetchGroups(shaKeyedCache)
        if allFetched.isEmpty {
            log("PollResultBuilder › buildGroupState — ⚠️ fetchGroups returned 0 groups; activeScopes may be empty or all scopes are unreachable")
        }
        log("PollResultBuilder › buildGroupState — allFetched=\(allFetched.count)")
        let liveGroups = allFetched.filter { $0.groupStatus != .completed }
        let doneGroups = allFetched.filter { $0.groupStatus == .completed }
        let liveIDs = Set(liveGroups.map { $0.id })
        let now = Date()
        var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
        // IMPORTANT: populate newSeenGroupIDs from doneGroups BEFORE calling
        // freezeVanishedGroups, so a group present in both paths fires the hook
        // exactly once (freezeVanishedGroups checks seenGroupIDs before firing).
        var newSeenGroupIDs = snapSeenGroupIDs
        for group in doneGroups {
            // isNew is keyed off seenGroupIDs, not the display cache, to prevent
            // re-notification when a group is evicted from snapGroupCache by trimGroupCache
            // (capped at groupCacheLimit = 30) but is still present in GitHub's feed.
            let isNew = !newSeenGroupIDs.contains(group.id)
            let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
            log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=\(isNew) runs=[\(runSummary)]")
            if isNew {
                let scope = scopeFromGroup(group)
                log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=true → scope=\(scope)")
                // Fire the hook for any hook-triggering conclusion: genuine failures
                // (isFailure) and cancellations. Success/skipped completions must not
                // trigger an alert. See JobConclusion.isHookConclusion for rationale.
                let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
                if shouldFire {
                    await fireFailureHook(group, scope)
                }
                newSeenGroupIDs.append(group.id)
            }
            newCache[group.id] = group.copying(isDimmed: true)
        }
        await freezeVanishedGroups(
            snapPrev: snapPrevGroups,
            liveIDs: liveIDs,
            now: now,
            into: &newCache,
            seenGroupIDs: newSeenGroupIDs,
            scopeFromGroup: scopeFromGroup,
            fireFailureHook: fireFailureHook
        )
        trimGroupCache(&newCache, limit: groupCacheLimit)
        trimSeenGroupIDs(&newSeenGroupIDs, limit: seenGroupIDsLimit)
        let newPrevLive = [String: WorkflowActionGroup](uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let display = buildGroupDisplay(live: liveGroups, cache: newCache)
        let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
        let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
        log(
            "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued"
                + " | cache: \(newCache.count) | seenIDs: \(newSeenGroupIDs.count) | display: \(display.count)"
        )
        // ── Sweep 1: enrich the display array ────────────────────────────────────────────
        // Keyed by Int (array index) so the sort order produced by buildGroupDisplay
        // is faithfully restored after withTaskGroup yields results in completion
        // order. Using a String group-ID key here would not be sufficient because
        // display can contain multiple entries with the same underlying group (e.g.
        // a live entry and a dimmed cache echo), so index is the only stable key.
        let enriched: [WorkflowActionGroup] = await withTaskGroup(
            of: (Int, WorkflowActionGroup).self
        ) { group in
            for (idx, actionGroup) in display.enumerated() {
                group.addTask { (idx, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
            }
            var out: [(Int, WorkflowActionGroup)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        // ── Sweep 2: enrich the group cache ──────────────────────────────────────────
        // Keyed by String (group ID) because newCache is a dictionary and its
        // semantic identity IS the group ID. These two sweeps cannot be merged
        // into one: the key types differ (Int vs String), the source collections
        // differ (display array vs newCache dict), and P16 (Actor-Per-Concern)
        // intentionally keeps display-enrichment and cache-enrichment separate so
        // neither path's concurrent mutations can interfere with the other.
        let enrichedCache: [String: WorkflowActionGroup] = await withTaskGroup(
            of: (String, WorkflowActionGroup).self
        ) { group in
            for (key, actionGroup) in newCache {
                group.addTask { (key, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
            }
            var out: [String: WorkflowActionGroup] = [:]
            for await (key, actionGroup) in group { out[key] = actionGroup }
            return out
        }
        return GroupPollResult(
            display: enriched,
            newGroupCache: enrichedCache,
            newPrevLiveGroups: newPrevLive,
            newSeenGroupIDs: newSeenGroupIDs
        )
    }

    // MARK: - Job helpers

    /// Moves jobs that vanished from the live feed into the completed-job cache.
    ///
    /// A job vanishes when it disappears from the API response without transitioning
    /// through a `completed` status — most commonly a cancellation or runner disconnect.
    /// Falls back to `.neutral` (not `.cancelled`) because `.cancelled` is the conclusion
    /// GitHub sets when a user explicitly cancels via the UI; a job that silently vanishes
    /// from the feed never received that API update. Using `.neutral` avoids misattributing
    /// the cause and keeps the display consistent with GitHub's own status page.
    public static func applyVanishedJobs(
        snapPrev: [Int: ActiveJob],
        liveIDs: Set<Int>,
        now: Date,
        into cache: inout [Int: ActiveJob]
    ) {
        for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
            guard cache[jobID] == nil else { continue }
            cache[jobID] = job.asCompleted(at: now)
        }
    }

    /// Trims the job cache to at most `limit` entries, keeping the most recently completed.
    public static func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        cache = [Int: ActiveJob](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Builds the ordered job display list from live jobs and the completed cache.
    ///
    /// Display order: in-progress → queued → cached (most-recently-completed first).
    /// Live jobs are never capped by `jobCacheLimit`; the combined list is capped
    /// at `jobDisplayLimit` so the panel UI stays manageable.
    public static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress: [ActiveJob] = live.filter { $0.status == .inProgress }
        let queued: [ActiveJob] = live.filter { $0.status == .queued }
        let cached: [ActiveJob] = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        // Use all live IDs (not just inProgress + queued) so that jobs in other
        // non-completed statuses (.waiting, .requested, .pending) also prevent
        // their stale dimmed cache entry from appearing in the display list.
        let liveJobIDs = Set(live.map { $0.id })
        var display: [ActiveJob] = []
        display.appendUpTo(jobDisplayLimit, from: inProgress)
        display.appendUpTo(jobDisplayLimit, from: queued)
        display.appendUpTo(jobDisplayLimit, from: cached) { !liveJobIDs.contains($0.id) }
        return display
    }

    // MARK: - Group helpers

    /// Returns a copy of the cache re-keyed by `headSha` instead of group ID.
    public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
    }

    /// Removes cache entries whose `headSha` appears in the freshly-fetched group list.
    ///
    /// A re-run on the same commit produces a new group ID for the same `headSha`.
    /// This method correctly evicts *all* cached groups for that SHA so the stale
    /// entries cannot ghost alongside the fresh live group.
    public static func evictFreshShas(
        from cache: [String: WorkflowActionGroup],
        freshGroups: [WorkflowActionGroup]
    ) -> [String: WorkflowActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    /// Freezes action groups that were live in the previous poll but have since
    /// vanished from the live feed (i.e. completed without appearing in fetchGroups).
    ///
    /// Fires `fireFailureHook` for unseen groups with a hook-triggering conclusion
    /// (`isHookConclusion` — genuine failures and cancellations).
    /// Successfully completed vanished groups are cached and dimmed without an alert.
    ///
    /// - Important: Both `snapPrev` and the `cache` parameter are keyed by
    ///   `WorkflowActionGroup.id`, **not** by `headSha`. `liveIDs` must also be a
    ///   `Set<String>` of `WorkflowActionGroup.id` values for the containment check to
    ///   be correct.
    public static func freezeVanishedGroups(
        snapPrev: [String: WorkflowActionGroup],
        liveIDs: Set<String>,
        now: Date,
        into cache: inout [String: WorkflowActionGroup],
        seenGroupIDs: OrderedSet<String> = [],
        scopeFromGroup: @Sendable (WorkflowActionGroup) -> String,
        fireFailureHook: @Sendable (WorkflowActionGroup, String) async -> Void
    ) async {
        log("PollResultBuilder › freezeVanishedGroups — snapPrev=\(snapPrev.count) liveIDs=\(liveIDs)")
        for (groupID, group) in snapPrev where !liveIDs.contains(groupID) {
            log("PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id) inCache=\(cache[groupID] != nil)")
            if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
                log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) already cached+dimmed, skipping")
                continue
            }
            if !seenGroupIDs.contains(groupID) && cache[groupID] == nil {
                let scope = scopeFromGroup(group)
                // Fire for any hook-triggering conclusion — failures and cancellations.
                // Do not fire for successful groups that vanished from the live feed normally.
                // See JobConclusion.isHookConclusion for full rationale.
                let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
                if shouldFire {
                    log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) unseen+hookConclusion → fireFailureHook scope=\(scope)")
                    await fireFailureHook(group, scope)
                }
            }
            if group.lastJobCompletedAt == nil {
                cache[groupID] = group.copying(isDimmed: true, settingCompletedAt: now)
            } else {
                cache[groupID] = group.copying(isDimmed: true)
            }
        }
    }

    /// Trims the group cache to at most `limit` entries, keeping the most recently completed.
    public static func trimGroupCache(_ cache: inout [String: WorkflowActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        cache = [String: WorkflowActionGroup](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Trims the seen-group-IDs set to at most `limit` entries, evicting the oldest first.
    ///
    /// `OrderedSet` preserves insertion order, so `removeFirst()` always evicts the
    /// entry that was seen earliest — true FIFO behaviour.
    /// The limit (200) is intentionally much larger than `groupCacheLimit` (30) so
    /// hook-suppression memory outlasts the display cache by a wide margin — a
    /// group evicted from the display cache cannot re-trigger the hook simply because
    /// it reappears in GitHub's feed on a subsequent poll.
    public static func trimSeenGroupIDs(_ ids: inout OrderedSet<String>, limit: Int) {
        guard ids.count > limit else { return }
        let excess = ids.count - limit
        ids.removeFirst(excess)
    }

    /// Builds the ordered group display list from live groups and the completed cache.
    ///
    /// Display order: in-progress → queued → cached (most-recently-completed first).
    /// Capped at `groupDisplayLimit` — analogous to `jobDisplayLimit` for jobs.
    public static func buildGroupDisplay(
        live: [WorkflowActionGroup],
        cache: [String: WorkflowActionGroup]
    ) -> [WorkflowActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let queued = live.filter { $0.groupStatus == .queued }
        // Use all live IDs (not just inProgress + queued) so that groups in other
        // non-completed statuses (.waiting, .requested, etc.) also prevent their
        // stale dimmed cache entry from appearing alongside the live entry.
        // Mirrors the identical reasoning in buildJobDisplay.
        let liveGroupIDs = Set(live.map { $0.id })
        let cached = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        var display: [WorkflowActionGroup] = []
        display.appendUpTo(groupDisplayLimit, from: inProgress)
        display.appendUpTo(groupDisplayLimit, from: queued)
        display.appendUpTo(groupDisplayLimit, from: cached) { !liveGroupIDs.contains($0.id) }
        return display
    }
}

// MARK: - Array fill helper

/// Sequence-filling helpers used by `PollResultBuilder` to top up display arrays.
private extension Array {
    /// Appends elements from `source` until `self.count` reaches `limit`.
    ///
    /// Elements are appended in source order. An optional predicate can skip
    /// individual elements (e.g. cached groups that are already live) without
    /// breaking the "fill until full" semantics.
    mutating func appendUpTo<S>(
        _ limit: Int,
        from source: S,
        where shouldAppend: (S.Element) -> Bool = { _ in true }
    ) where S: Sequence, S.Element == Element {
        guard count < limit else { return }
        for element in source where count < limit && shouldAppend(element) {
            append(element)
        }
    }
}
