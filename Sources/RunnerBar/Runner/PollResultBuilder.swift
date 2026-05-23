import Foundation

// MARK: - PollResultBuilder

/// Pure state-building logic extracted from RunnerStore.
/// All methods are static and operate only on data passed as parameters.
/// Fetch / API side-effects are injected as closures so this type is
/// independently unit-testable without a RunnerStore instance.
struct PollResultBuilder {

    // MARK: - Cache limits

    static let jobCacheLimit = 3
    static let groupCacheLimit = 30

    // MARK: - Job state

    /// Builds the job display list and updated caches from a background poll snapshot.
    ///
    /// - Parameters:
    ///   - snapPrev: Live-job snapshot from the previous poll.
    ///   - snapCache: Completed-job cache from the previous poll.
    ///   - fetchJobs: Closure that fetches live jobs for every active scope.
    ///   - backfill: Closure that backfills step data into a completed-job cache entry.
    static func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob],
        fetchJobs: () -> [ActiveJob],
        backfill: (inout [Int: ActiveJob]) -> Void
    ) -> JobPollResult {
        let allFetched = fetchJobs()
        let liveJobs = allFetched.filter { $0.conclusion == nil && $0.status != "completed" }
        let freshDone = allFetched.filter { $0.conclusion != nil || $0.status == "completed" }
        let liveIDs = Set(liveJobs.map { $0.id })
        let now = Date()
        var newCache = snapCache
        applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
        for job in freshDone {
            newCache[job.id] = ActiveJob(
                id: job.id,
                name: job.name,
                status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt,
                createdAt: job.createdAt,
                completedAt: job.completedAt ?? Date(),
                htmlUrl: job.htmlUrl,
                isDimmed: true,
                steps: job.steps,
                runnerName: job.runnerName
            )
        }
        trimJobCache(&newCache, limit: jobCacheLimit)
        backfill(&newCache)
        let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
        let display = buildJobDisplay(live: liveJobs, cache: newCache)
        let inProgCount = liveJobs.filter { $0.status == "in_progress" }.count
        let queuedCount = liveJobs.filter { $0.status == "queued" }.count
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
    ///   - jobCache: Completed-job cache used to enrich group jobs.
    ///   - fetchGroups: Closure that fetches live groups for every active scope.
    ///   - scopeFromGroup: Closure that derives a scope string from an WorkflowActionGroup.
    ///   - fireFailureHook: Closure invoked the first time a group is seen as completed.
    ///   - enrichJobs: Closure that enriches a job list from the job cache.
    static func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        jobCache: [Int: ActiveJob],
        fetchGroups: ([String: WorkflowActionGroup]) -> [WorkflowActionGroup],
        scopeFromGroup: (WorkflowActionGroup) -> String,
        fireFailureHook: (WorkflowActionGroup, String) -> Void,
        enrichJobs: ([ActiveJob]) -> [ActiveJob]
    ) -> GroupPollResult {
        log("PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count)")
        let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
        let allFetched = fetchGroups(shaKeyedCache)
        // Early-exit diagnostic: if fetchGroups returned nothing, active scopes are
        // likely empty or misconfigured. Log clearly so it's easy to diagnose.
        if allFetched.isEmpty {
            log("PollResultBuilder › buildGroupState — ⚠️ fetchGroups returned 0 groups; activeScopes may be empty or all scopes are unreachable")
        }
        log("PollResultBuilder › buildGroupState — allFetched=\(allFetched.count)")
        let liveGroups = allFetched.filter { $0.groupStatus != .completed }
        let doneGroups = allFetched.filter { $0.groupStatus == .completed }
        let liveIDs = Set(liveGroups.map { $0.id })
        let now = Date()
        var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
        freezeVanishedGroups(
            snapPrev: snapPrevGroups,
            liveIDs: liveIDs,
            now: now,
            into: &newCache,
            scopeFromGroup: scopeFromGroup,
            fireFailureHook: fireFailureHook
        )
        for group in doneGroups {
            let isNew = snapGroupCache[group.id] == nil
            let runSummary = group.runs.map { "\($0.id):\($0.conclusion ?? "nil")" }.joined(separator: ", ")
            log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=\(isNew) runs=[\(runSummary)]")
            if isNew {
                let scope = scopeFromGroup(group)
                log("PollResultBuilder › doneGroups — groupID=\(group.id) isNew=true → fireFailureHook scope=\(scope)")
                fireFailureHook(group, scope)
            }
            var dimmed = group
            dimmed.isDimmed = true
            newCache[group.id] = dimmed
        }
        trimGroupCache(&newCache, limit: groupCacheLimit)
        let newPrevLive = Dictionary(uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let display = buildGroupDisplay(live: liveGroups, cache: newCache)
        let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
        let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
        log(
            "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued"
            + " | cache: \(newCache.count) | display: \(display.count)"
        )
        let enriched = display.map { $0.withJobs(enrichJobs($0.jobs)) }
        let enrichedCache = newCache.mapValues { $0.withJobs(enrichJobs($0.jobs)) }
        return GroupPollResult(
            display: enriched,
            newGroupCache: enrichedCache,
            newPrevLiveGroups: newPrevLive
        )
    }

    // MARK: - Private job helpers

    static func applyVanishedJobs(
        snapPrev: [Int: ActiveJob],
        liveIDs: Set<Int>,
        now: Date,
        into cache: inout [Int: ActiveJob]
    ) {
        for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
            guard cache[jobID] == nil else { continue }
            cache[jobID] = ActiveJob(
                id: job.id,
                name: job.name,
                status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt,
                createdAt: job.createdAt,
                completedAt: job.completedAt ?? now,
                htmlUrl: job.htmlUrl,
                isDimmed: true,
                steps: job.steps,
                runnerName: job.runnerName
            )
        }
    }

    static func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress = live.filter { $0.status == "in_progress" }
        let queued     = live.filter { $0.status == "queued" }
        let cached     = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        var display: [ActiveJob] = []
        for job in inProgress where display.count < jobCacheLimit { display.append(job) }
        for job in queued     where display.count < jobCacheLimit { display.append(job) }
        for job in cached     where display.count < jobCacheLimit { display.append(job) }
        return display
    }

    // MARK: - Private group helpers

    static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
    }

    static func evictFreshShas(
        from cache: [String: WorkflowActionGroup],
        freshGroups: [WorkflowActionGroup]
    ) -> [String: WorkflowActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    /// Freezes action groups that were live in the previous poll but have since
    /// vanished from the live feed (i.e. completed without appearing in fetchGroups).
    ///
    /// - Important: Both `snapPrev` and the `cache` parameter are keyed by
    ///   `WorkflowActionGroup.id`, **not** by `headSha`. `liveIDs` must also be a
    ///   `Set<String>` of `WorkflowActionGroup.id` values for the containment check to
    ///   be correct. Do not rekey either dictionary by headSha without updating
    ///   all three sites consistently.
    static func freezeVanishedGroups(
        snapPrev: [String: WorkflowActionGroup],
        liveIDs: Set<String>,
        now: Date,
        into cache: inout [String: WorkflowActionGroup],
        scopeFromGroup: (WorkflowActionGroup) -> String,
        fireFailureHook: (WorkflowActionGroup, String) -> Void
    ) {
        log("PollResultBuilder › freezeVanishedGroups — snapPrev=\(snapPrev.count) liveIDs=\(liveIDs)")
        // groupID is WorkflowActionGroup.id — the dictionary key for both snapPrev and cache.
        // (Do not confuse with headSha, which is a separate property on WorkflowActionGroup.)
        for (groupID, group) in snapPrev where !liveIDs.contains(groupID) {
            log("PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id) inCache=\(cache[groupID] != nil)")
            if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
                log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) already cached+dimmed, skipping")
                continue
            }
            if cache[groupID] == nil {
                let scope = scopeFromGroup(group)
                log("PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) cache[groupID]==nil → fireFailureHook scope=\(scope)")
                fireFailureHook(group, scope)
            }
            var frozen = group
            frozen.isDimmed = true
            if frozen.lastJobCompletedAt == nil {
                frozen = WorkflowActionGroup(
                    headSha: frozen.headSha,
                    label: frozen.label,
                    title: frozen.title,
                    headBranch: frozen.headBranch,
                    repo: frozen.repo,
                    runs: frozen.runs,
                    jobs: frozen.jobs,
                    firstJobStartedAt: frozen.firstJobStartedAt,
                    lastJobCompletedAt: now,
                    createdAt: frozen.createdAt,
                    isDimmed: true
                )
            }
            cache[groupID] = frozen
        }
    }

    static func trimGroupCache(_ cache: inout [String: WorkflowActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        // Cache is keyed by WorkflowActionGroup.id — preserve that key when rebuilding.
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    static func buildGroupDisplay(
        live: [WorkflowActionGroup],
        cache: [String: WorkflowActionGroup]
    ) -> [WorkflowActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let queued     = live.filter { $0.groupStatus == .queued }
        let liveIDs    = Set((inProgress + queued).map { $0.id })
        let cached     = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        var display: [WorkflowActionGroup] = []
        for grp in inProgress where display.count < groupCacheLimit                           { display.append(grp) }
        for grp in queued     where display.count < groupCacheLimit                           { display.append(grp) }
        for grp in cached     where display.count < groupCacheLimit && !liveIDs.contains(grp.id) { display.append(grp) }
        return display
    }
}
