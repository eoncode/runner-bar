import Foundation

// MARK: - Poll result value types

/// Result returned by `RunnerStore.buildJobState(_:)`.
struct JobPollResult {
    /// Jobs to display in the popover (in_progress → queued → cached done).
    let display: [ActiveJob]
    /// Updated completed-job cache, trimmed to 3 entries.
    let newCache: [Int: ActiveJob]
    /// Live-job snapshot for the next poll's diff.
    let newPrevLive: [Int: ActiveJob]
}

/// Result returned by `RunnerStore.buildGroupState(_:)`.
struct GroupPollResult {
    /// Action groups to display in the popover.
    let display: [ActionGroup]
    /// Updated group cache, trimmed to 5 entries.
    let newGroupCache: [String: ActionGroup]
    /// Live-group snapshot for the next poll's diff.
    let newPrevLiveGroups: [String: ActionGroup]
}

// MARK: - Job state builder

/// RunnerStore extension providing the job-state builder used by the background poll.
extension RunnerStore {
    /// Builds the job display list and updated caches from a background poll.
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

        // ⚠️ CALLSITE 2 of 3 — Vanished jobs: were live last poll, gone now.
        for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
            guard newCache[jobID] == nil else { continue }
            newCache[jobID] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt ?? now,
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }

        // ⚠️ CALLSITE 3 of 3 — Fresh done: jobs with a conclusion inside active runs.
        for job in freshDone {
            newCache[job.id] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt ?? Date(),
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }

        trimJobCache(&newCache, limit: 3)
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

    /// Trims the job cache to the `limit` most-recently-completed entries.
    private func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Backfills missing steps for cached completed jobs via the single-job API (#110/#111).
    private func backfillSteps(into cache: inout [Int: ActiveJob]) {
        let iso = ISO8601DateFormatter()
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty
                  || cached.steps.contains(where: { $0.status == "in_progress" }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                  let rawSteps = fresh.steps,
                  !rawSteps.isEmpty
            else { continue }
            cache[cacheID] = makeActiveJob(from: fresh, iso: iso, isDimmed: true)
        }
    }

    /// Assembles the ordered display list: in_progress → queued → cached done, capped at 3.
    private func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress = live.filter { $0.status == "in_progress" }
        let queued = live.filter { $0.status == "queued" }
        let cached = cache.values
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        var display: [ActiveJob] = []
        for job in inProgress where display.count < 3 { display.append(job) }
        for job in queued     where display.count < 3 { display.append(job) }
        for job in cached     where display.count < 3 { display.append(job) }
        return display
    }

    // MARK: - Job enrichment

    /// Merges step data from `jobCache` into a flat job list.
    /// Returns the same jobs with steps backfilled from cache where the live
    /// job has no steps yet. No-op if `jobs` is empty or cache has no match.
    func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        guard !jobs.isEmpty else { return jobs }
        return jobs.map { job in
            guard job.steps.isEmpty, let cached = jobCache[job.id], !cached.steps.isEmpty
            else { return job }
            return ActiveJob(
                id: job.id, name: job.name, status: job.status,
                conclusion: job.conclusion,
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt,
                htmlUrl: job.htmlUrl, isDimmed: job.isDimmed,
                steps: cached.steps
            )
        }
    }
}

// MARK: - Group state builder

/// RunnerStore extension providing the group-state builder used by the background poll.
extension RunnerStore {
    /// Builds the action-group display list and updated caches from a background poll.
    func buildGroupState(
        snapPrevGroups: [String: ActionGroup],
        snapGroupCache: [String: ActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
        var allFetched: [ActionGroup] = []
        for scope in ScopeStore.shared.scopes {
            allFetched.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedCache))
        }
        let liveGroups = allFetched.filter { $0.groupStatus != .completed }
        let doneGroups = allFetched.filter { $0.groupStatus == .completed }
        let liveIDs = Set(liveGroups.map { $0.id })
        let now = Date()
        var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)

        freezeVanishedGroups(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now, into: &newCache)
        for group in doneGroups {
            var dimmed = group
            dimmed.isDimmed = true
            newCache[group.id] = dimmed
        }
        trimGroupCache(&newCache, limit: 5)

        let newPrevLive = Dictionary(uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let display = buildGroupDisplay(live: liveGroups, cache: newCache)
        let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
        let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
        log(
            "RunnerStore › groups: \(inProgCount) in_progress \(queuedCount) queued"
            + " | cache: \(newCache.count) | display: \(display.count)"
        )
        let enriched = display.map { $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache)) }
        let enrichedCache = newCache.mapValues {
            $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache))
        }
        return GroupPollResult(
            display: enriched, newGroupCache: enrichedCache, newPrevLiveGroups: newPrevLive
        )
    }

    /// Rebuilds the cache keyed by head_sha for `fetchActionGroups`.
    private func makeShaKeyedCache(_ cache: [String: ActionGroup]) -> [String: ActionGroup] {
        Dictionary(
            cache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
    }

    /// Removes cache entries whose head_sha appears in freshly-fetched groups.
    private func evictFreshShas(
        from cache: [String: ActionGroup],
        freshGroups: [ActionGroup]
    ) -> [String: ActionGroup] {
        let freshShas = Set(freshGroups.map { $0.headSha })
        return cache.filter { !freshShas.contains($0.value.headSha) }
    }

    /// Freezes groups that were live last poll but absent this poll.
    private func freezeVanishedGroups(
        snapPrev: [String: ActionGroup],
        liveIDs: Set<String>,
        now: Date,
        into cache: inout [String: ActionGroup]
    ) {
        for (sha, group) in snapPrev where !liveIDs.contains(sha) {
            if let existing = cache[sha],
               existing.isDimmed,
               existing.jobs.count >= group.jobs.count { continue }
            var frozen = group
            frozen.isDimmed = true
            if frozen.lastJobCompletedAt == nil {
                frozen = ActionGroup(
                    headSha: frozen.headSha, label: frozen.label,
                    title: frozen.title, headBranch: frozen.headBranch,
                    repo: frozen.repo, runs: frozen.runs, jobs: frozen.jobs,
                    firstJobStartedAt: frozen.firstJobStartedAt,
                    lastJobCompletedAt: now, createdAt: frozen.createdAt,
                    isDimmed: true
                )
            }
            cache[sha] = frozen
        }
    }

    /// Trims the group cache to the `limit` most-recently-completed entries.
    private func trimGroupCache(_ cache: inout [String: ActionGroup], limit: Int) {
        guard cache.count > limit else { return }
        let sorted = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
            > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        cache = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.id, $0) })
    }

    /// Assembles the ordered group display list: in_progress → queued → cached done, capped at 5.
    private func buildGroupDisplay(
        live: [ActionGroup],
        cache: [String: ActionGroup]
    ) -> [ActionGroup] {
        let inProgress = live.filter { $0.groupStatus == .inProgress }
        let queued = live.filter { $0.groupStatus == .queued }
        let liveDisplayIDs = Set((inProgress + queued).map { $0.id })
        let cached = cache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
            > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        var display: [ActionGroup] = []
        for grp in inProgress where display.count < 5 { display.append(grp) }
        for grp in queued     where display.count < 5 { display.append(grp) }
        for grp in cached where display.count < 5 && !liveDisplayIDs.contains(grp.id) {
            display.append(grp)
        }
        return display
    }
}
