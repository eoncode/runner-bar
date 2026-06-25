// PollResultBuilder.swift
// RunnerBarCore
import Collections
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
    // swiftlint:disable function_parameter_count

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
        snapSeenGroupIDs: OrderedSet<String>,
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
        var newSeenGroupIDs = snapSeenGroupIDs
        for group in doneGroups {
            let isNew = !newSeenGroupIDs.contains(group.id)
            let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
            log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=\(isNew) runs=[\(runSummary)]")
            if isNew {
                let scope = scopeFromGroup(group)
                log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=true → scope=\(scope)")
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
            seenGroupIDs: &newSeenGroupIDs,
            scopeFromGroup: scopeFromGroup,
            fireFailureHook: fireFailureHook
        )
        trimGroupCache(&newCache, limit: groupCacheLimit)
        trimSeenGroupIDs(&newSeenGroupIDs, limit: seenGroupIDsLimit)
        let newPrevLive = [String: WorkflowActionGroup](uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let display = buildGroupDisplay(live: liveGroups, cache: newCache)
        let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
        let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
        let loadingCount = liveGroups.filter { $0.groupStatus == .loading }.count
        log(
            "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued \(loadingCount) loading"
                + " | cache: \(newCache.count) | seenIDs: \(newSeenGroupIDs.count) | display: \(display.count)"
        )
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

    /// Moves jobs that were live in the previous snapshot but are absent from the current
    /// live poll into `cache` as completed entries.
    ///
    /// A job that disappears without a conclusion (vanished) is given a `.neutral` conclusion
    /// and marked dimmed. Existing cache entries for vanished jobs are never overwritten.
    ///
    /// - Parameters:
    ///   - snapPrev: Live-job snapshot from the previous poll cycle.
    ///   - liveIDs: Set of job IDs present in the current live poll.
    ///   - now: Timestamp to use as `completedAt` for vanished jobs.
    ///   - cache: Completed-job cache to mutate.
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

    /// Evicts the oldest completed-job cache entries until `cache.count <= limit`.
    ///
    /// Entries are sorted by `completedAt` descending so the most-recently-completed
    /// jobs are retained. Jobs without a `completedAt` date sort to the end and are
    /// evicted first.
    ///
    /// - Parameters:
    ///   - cache: Completed-job cache to mutate in place.
    ///   - limit: Maximum number of entries to retain.
    public static func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        cache = [Int: ActiveJob](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Combines live and cached jobs into the ordered display list shown in the panel.
    ///
    /// In-progress jobs appear before queued jobs, which appear before cached completed
    /// jobs. The total list is capped at `jobDisplayLimit`; live jobs are never truncated
    /// by `jobCacheLimit`.
    ///
    /// - Parameters:
    ///   - live: Currently active jobs from the latest poll.
    ///   - cache: Completed-job cache from the latest poll cycle.
    public static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress: [ActiveJob] = live.filter { $0.status == .inProgress }
        let queued: [ActiveJob] = live.filter { $0.status == .queued }
        let cached: [ActiveJob] = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        let liveJobIDs = Set(live.map { $0.id })
        var display: [ActiveJob] = []
        display.appendUpTo(jobDisplayLimit, from: inProgress)
        display.appendUpTo(jobDisplayLimit, from: queued)
        display.appendUpTo(jobDisplayLimit, from: cached) { !liveJobIDs.contains($0.id) }
        return display
    }

    // MARK: - Group helpers

    /// Returns a SHA-keyed view of `cache`, used to detect whether a fetched group's
    /// SHA already has a cached entry (for stale-row self-healing).
    ///
    /// When two cache entries share the same `headSha`, the one with the larger `id`
    /// (more recent run) is retained. Tie-breaking uses numeric integer comparison
    /// to avoid lexicographic ordering issues across digit boundaries (e.g. "9" vs "10").
    ///
    /// - Parameter cache: The current group cache keyed by run ID.
    public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in (Int(lhs.id) ?? 0) > (Int(rhs.id) ?? 0) ? lhs : rhs }
        )
    }

    /// Returns a copy of `cache` with all entries whose `headSha` appears in
    /// `freshGroups` removed.
    ///
    /// Called at the start of every poll so that freshly-fetched groups replace
    /// their stale cached counterparts rather than coexisting with them.
    ///
    /// - Parameters:
    ///   - cache: Current group cache to filter.
    ///   - freshGroups: Groups returned by the latest fetch.
    public static func evictFreshShas(
        from cache: [String: WorkflowActionGroup],
        freshGroups: [WorkflowActionGroup]
    ) -> [String: WorkflowActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    /// Moves groups that were live in `snapPrev` but absent from the current live
    /// set into `cache` as dimmed completed entries, firing the failure hook when
    /// appropriate.
    ///
    /// A group whose `lastJobCompletedAt` is nil receives the current timestamp so
    /// the cache sort order remains stable.
    ///
    /// The fired group's ID is appended to `seenGroupIDs` (`inout`) so the caller's
    /// `newSeenGroupIDs` reflects the vanish-path fires and the hook cannot re-fire
    /// on a subsequent poll if the group reappears in `snapPrevGroups`.
    ///
    /// - Parameters:
    ///   - snapPrev: Live-group snapshot from the previous poll cycle.
    ///   - liveIDs: Set of group IDs present in the current live poll.
    ///   - now: Timestamp used as `lastJobCompletedAt` for vanished groups that lack one.
    ///   - cache: Group cache to mutate.
    ///   - seenGroupIDs: Set of group IDs that have already fired the hook; mutated in place
    ///     when a vanished group fires so the caller's set stays consistent.
    ///   - scopeFromGroup: Derives the scope string for the failure hook call.
    ///   - fireFailureHook: Invoked when a newly-vanished group has a hook-triggering conclusion.
    public static func freezeVanishedGroups(
        snapPrev: [String: WorkflowActionGroup],
        liveIDs: Set<String>,
        now: Date,
        into cache: inout [String: WorkflowActionGroup],
        seenGroupIDs: inout OrderedSet<String>,
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
                let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
                if shouldFire {
                    log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) unseen+hookConclusion → fireFailureHook scope=\(scope)")
                    await fireFailureHook(group, scope)
                }
                seenGroupIDs.append(groupID)
            }
            if group.lastJobCompletedAt == nil {
                cache[groupID] = group.copying(isDimmed: true, settingCompletedAt: now)
            } else {
                cache[groupID] = group.copying(isDimmed: true)
            }
        }
    }

    /// Evicts the oldest completed-group cache entries until `cache.count <= limit`.
    ///
    /// Entries are sorted by `lastJobCompletedAt` (falling back to `createdAt`) descending
    /// so the most recently completed groups are retained.
    ///
    /// - Parameters:
    ///   - cache: Group cache to mutate in place.
    ///   - limit: Maximum number of entries to retain.
    public static func trimGroupCache(_ cache: inout [String: WorkflowActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        cache = [String: WorkflowActionGroup](uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Evicts the oldest entries from `ids` (FIFO) until `ids.count <= limit`.
    ///
    /// Because `ids` is an `OrderedSet`, the elements with the lowest indices
    /// (inserted earliest) are removed first, giving true FIFO eviction.
    ///
    /// - Parameters:
    ///   - ids: The seen-group-IDs set to trim in place.
    ///   - limit: Maximum number of entries to retain.
    public static func trimSeenGroupIDs(_ ids: inout OrderedSet<String>, limit: Int) {
        guard ids.count > limit else { return }
        let excess = ids.count - limit
        ids.removeFirst(excess)
    }

    /// Combines live and cached groups into the ordered display list shown in the panel.
    ///
    /// Display order: in-progress → loading → queued → cached (most-recently-completed first).
    /// The total list is capped at `groupDisplayLimit`.
    ///
    /// - Parameters:
    ///   - live: Currently active groups from the latest poll.
    ///   - cache: Completed-group cache from the latest poll cycle.
    public static func buildGroupDisplay(
        live: [WorkflowActionGroup],
        cache: [String: WorkflowActionGroup]
    ) -> [WorkflowActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let loading    = live.filter { $0.groupStatus == .loading }
        let queued     = live.filter { $0.groupStatus == .queued }
        // Use all live IDs (not just inProgress + queued) so that groups in other
        // non-completed statuses (.loading, .waiting, .requested, etc.) also prevent
        // their stale dimmed cache entry from appearing alongside the live entry.
        let liveGroupIDs = Set(live.map { $0.id })
        let cached = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        var display: [WorkflowActionGroup] = []
        display.appendUpTo(groupDisplayLimit, from: inProgress)
        display.appendUpTo(groupDisplayLimit, from: loading)
        display.appendUpTo(groupDisplayLimit, from: queued)
        display.appendUpTo(groupDisplayLimit, from: cached) { !liveGroupIDs.contains($0.id) }
        return display
    }
}

// MARK: - Array fill helper

/// Array extension providing a bounded fill method used by the display-list builders.
/// Appends elements from a source sequence up to a specified limit, with an optional
/// filter predicate.
private extension Array {
    /// Appends elements from `source` to `self` up to `limit` total elements,
    /// optionally filtered by `shouldAppend`.
    ///
    /// Does nothing if `self.count >= limit` on entry.
    ///
    /// - Parameters:
    ///   - limit: Maximum total count of `self` after appending.
    ///   - source: Sequence of elements to draw from.
    ///   - shouldAppend: Optional predicate; defaults to accepting all elements.
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
