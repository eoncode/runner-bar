import Foundation

// MARK: - Poll result value types

// Result returned by `RunnerStore.buildJobState(_:)`.
struct JobPollResult {
    // Jobs to display in the popover (in_progress → queued → cached done).
    let display: [ActiveJob]
    // Updated completed-job cache, trimmed to jobCacheLimit entries.
    let newCache: [Int: ActiveJob]
    // Live-job snapshot for the next poll's diff.
    let newPrevLive: [Int: ActiveJob]
}

// Result returned by `RunnerStore.buildGroupState(_:)`.
struct GroupPollResult {
    // Action groups to display in the popover.
    let display: [ActionGroup]
    // Updated group cache, trimmed to groupCacheLimit entries.
    let newGroupCache: [String: ActionGroup]
    // Live-group snapshot for the next poll's diff.
    let newPrevLiveGroups: [String: ActionGroup]
}

// MARK: - Cache limits

/// Maximum number of completed jobs retained in the display cache.
private let jobCacheLimit = 3
/// Maximum number of completed action groups retained in the display cache.
private let groupCacheLimit = 30

// MARK: - Job state builder

// RunnerStore extension providing the job-state builder used by the background poll.
extension RunnerStore {
    // Builds the job display list and updated caches from a background poll snapshot.
    func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        var allFetched: [ActiveJob] = []
        for scope in ScopeStore.shared.scopes {
            allFetched.append(contentsOf: fetchActiveJobs(for: scope))
        }
        let liveJobs = allFetched.filter { $0.conclusion == nil && $0.status != "completed" }
        let freshDone = allFetched.filter { $0.conclusion != nil || $0.status == "completed" }
        let liveIDs = Set(liveJobs.map { $0.id })
        let now = Date()
        var newCache = snapCache
        applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
        // ⚠️ CALLSITE 3 of 3 — Fresh done: jobs with a conclusion inside active runs.
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
        backfillSteps(into: &newCache)
        let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
        let display = buildJobDisplay(live: liveJobs, cache: newCache)
        let inProgCount = liveJobs.filter { $0.status == "in_progress" }.count
        let queuedCount = liveJobs.filter { $0.status == "queued" }.count
        log(
            "RunnerStore › \(inProgCount) in_progress \(queuedCount) queued"
            + " | cache: \(newCache.count) | display: \(display.count)"
        )
        return JobPollResult(display: display, newCache: newCache, newPrevLive: newPrevLive)
    }

    // Inserts completed stubs for jobs that were live last poll but have since vanished.
    private func applyVanishedJobs(
        snapPrev: [Int: ActiveJob],
        liveIDs: Set<Int>,
        now: Date,
        into cache: inout [Int: ActiveJob]
    ) {
        // ⚠️ CALLSITE 2 of 3 — Vanished jobs: were live last poll, gone now.
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

    private func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted { lhs, rhs in
            (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    private func backfillSteps(into cache: inout [Int: ActiveJob]) {
        let iso = ISO8601DateFormatter()
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty || cached.steps.contains(where: { $0.status == "in_progress" }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                  let rawSteps = fresh.steps,
                  !rawSteps.isEmpty
            else { continue }
            cache[cacheID] = makeActiveJob(from: fresh, iso: iso, isDimmed: true)
        }
    }

    private func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress = live.filter { $0.status == "in_progress" }
        let queued = live.filter { $0.status == "queued" }
        let cached = cache.values.sorted { lhs, rhs in
            (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
        var display: [ActiveJob] = []
        for job in inProgress where display.count < jobCacheLimit { display.append(job) }
        for job in queued where display.count < jobCacheLimit { display.append(job) }
        for job in cached where display.count < jobCacheLimit { display.append(job) }
        return display
    }
}

// MARK: - Group state builder

// RunnerStore extension providing the group-state builder used by the background poll.
extension RunnerStore {
    // Builds the action-group display list and updated caches from a background poll.
    func buildGroupState(
        snapPrevGroups: [String: ActionGroup],
        snapGroupCache: [String: ActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        let scopes = ScopeStore.shared.scopes
        log("RunnerStore › buildGroupState — scopes=\(scopes) snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ buildGroupState — scopes is EMPTY, returning empty GroupPollResult")
            return GroupPollResult(display: [], newGroupCache: snapGroupCache, newPrevLiveGroups: snapPrevGroups)
        }
        let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
        var allFetched: [ActionGroup] = []
        for scope in scopes {
            log("RunnerStore › buildGroupState — fetching scope=\(scope)")
            allFetched.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedCache))
        }
        log("RunnerStore › buildGroupState — allFetched.count=\(allFetched.count)")
        let liveGroups = allFetched.filter { $0.groupStatus != .completed }
        let doneGroups = allFetched.filter { $0.groupStatus == .completed }
        let liveIDs = Set(liveGroups.map { $0.id })
        let now = Date()
        log("RunnerStore › buildGroupState — liveGroups=\(liveGroups.count) doneGroups=\(doneGroups.count)")
        log("RunnerStore › buildGroupState — doneGroups IDs: \(doneGroups.map { $0.id })")
        log("RunnerStore › buildGroupState — snapGroupCache keys: \(snapGroupCache.keys.sorted())")
        var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
        freezeVanishedGroups(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now, into: &newCache, prevLiveGroups: snapPrevGroups)
        // Cache done groups; fire failure hook the first time a group is seen as completed.
        // Uses snapGroupCache[group.id] == nil as the "newly completed" signal.
        for group in doneGroups {
            let isNew = snapGroupCache[group.id] == nil
            let runSummary = group.runs.map { "\($0.id):\($0.conclusion ?? "nil")" }.joined(separator: ", ")
            log("RunnerStore › doneGroups — groupID=\(group.id) title=\(group.title) headSha=\(group.headSha) isNew=\(isNew) inSnapGroupCache=\(snapGroupCache[group.id] != nil) runs=[\(runSummary)]")
            if isNew {
                let scope = scopeFromActionGroup(group)
                log("RunnerStore › doneGroups — groupID=\(group.id) isNew=true → calling FailureHookRunner.fireIfNeeded scope=\(scope)")
                FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "doneGroups")
            } else {
                log("RunnerStore › doneGroups — groupID=\(group.id) isNew=false → skipping fireIfNeeded (already in cache)")
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
            "RunnerStore › groups: \(inProgCount) in_progress \(queuedCount) queued"
            + " | cache: \(newCache.count) | display: \(display.count)"
        )
        let enriched = display.map({ $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache)) })
        let enrichedCache = newCache.mapValues({ $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache)) })
        return GroupPollResult(
            display: enriched,
            newGroupCache: enrichedCache,
            newPrevLiveGroups: newPrevLive
        )
    }

    /// Derives the scope string from an ActionGroup's repo field or runs.
    private func scopeFromActionGroup(_ group: ActionGroup) -> String {
        log("RunnerStore › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)")
        if !group.repo.isEmpty {
            log("RunnerStore › scopeFromActionGroup — using group.repo='\(group.repo)'")
            return group.repo
        }
        // Fallback: derive from first run's html_url using the shared scopeFromHtmlUrl helper.
        if let firstRun = group.runs.first, let url = firstRun.htmlUrl {
            log("RunnerStore › scopeFromActionGroup — group.repo empty, trying htmlUrl='\(url)'")
            if let derived = scopeFromHtmlUrl(url) {
                log("RunnerStore › scopeFromActionGroup — derived scope='\(derived)' from htmlUrl")
                return derived
            }
        }
        log("RunnerStore › ⚠️ scopeFromActionGroup — could not derive scope, returning empty string! groupID=\(group.id)")
        return ""
    }

    private func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasMoreSteps = cached.steps.count > job.steps.count
            return (cacheHasConclusion || cacheHasMoreSteps) ? cached : job
        }
    }

    private func makeShaKeyedCache(_ cache: [String: ActionGroup]) -> [String: ActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
    }

    private func evictFreshShas(
        from cache: [String: ActionGroup],
        freshGroups: [ActionGroup]
    ) -> [String: ActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    private func freezeVanishedGroups(
        snapPrev: [String: ActionGroup],
        liveIDs: Set<String>,
        now: Date,
        into cache: inout [String: ActionGroup],
        prevLiveGroups: [String: ActionGroup]
    ) {
        log("RunnerStore › freezeVanishedGroups — snapPrev.count=\(snapPrev.count) liveIDs=\(liveIDs)")
        for (sha, group) in snapPrev where !liveIDs.contains(sha) {
            log("RunnerStore › freezeVanishedGroups — vanished groupID=\(group.id) sha=\(sha) inCache=\(cache[sha] != nil)")
            if let existing = cache[sha], existing.isDimmed, existing.jobs.count >= group.jobs.count {
                log("RunnerStore › freezeVanishedGroups — groupID=\(group.id) already cached+dimmed, skipping")
                continue
            }
            // Fire failure hook for vanished groups not already cached (first time we see them gone).
            if cache[sha] == nil {
                let scope = scopeFromActionGroup(group)
                log("RunnerStore › freezeVanishedGroups — groupID=\(group.id) cache[sha]==nil → calling FailureHookRunner.fireIfNeeded scope=\(scope)")
                FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "freezeVanished")
            } else {
                log("RunnerStore › freezeVanishedGroups — groupID=\(group.id) cache[sha] already exists, skipping fireIfNeeded")
            }
            var frozen = group
            frozen.isDimmed = true
            if frozen.lastJobCompletedAt == nil {
                frozen = ActionGroup(
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
            cache[sha] = frozen
        }
    }

    private func trimGroupCache(_ cache: inout [String: ActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted(by: { lhs, rhs in
            (lhs.lastJobCompletedAt ?? lhs.createdAt ?? .distantPast)
                > (rhs.lastJobCompletedAt ?? rhs.createdAt ?? .distantPast)
        })
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    private func buildGroupDisplay(
        live: [ActionGroup],
        cache: [String: ActionGroup]
    ) -> [ActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let queued = live.filter { $0.groupStatus == .queued }
        let liveDisplayIDs = Set((inProgress + queued).map { $0.id })
        let cached = cache.values.sorted(by: { lhs, rhs in
            (lhs.lastJobCompletedAt ?? lhs.createdAt ?? .distantPast)
                > (rhs.lastJobCompletedAt ?? rhs.createdAt ?? .distantPast)
        })
        var display: [ActionGroup] = []
        for grp in inProgress where display.count < groupCacheLimit { display.append(grp) }
        for grp in queued where display.count < groupCacheLimit { display.append(grp) }
        for grp in cached where display.count < groupCacheLimit && !liveDisplayIDs.contains(grp.id) { display.append(grp) }
        return display
    }
}
