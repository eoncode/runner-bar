import Foundation

// MARK: - Poll result value types

// Result returned by `PollResultBuilder.buildJobState`.
struct JobPollResult {
    // Jobs to display in the popover (in_progress → queued → cached done).
    let display: [ActiveJob]
    // Updated completed-job cache, trimmed to jobCacheLimit entries.
    let newCache: [Int: ActiveJob]
    // Live-job snapshot for the next poll's diff.
    let newPrevLive: [Int: ActiveJob]
}

// Result returned by `PollResultBuilder.buildGroupState`.
struct GroupPollResult {
    // Action groups to display in the popover.
    let display: [ActionGroup]
    // Updated group cache, trimmed to groupCacheLimit entries.
    let newGroupCache: [String: ActionGroup]
    // Live-group snapshot for the next poll's diff.
    let newPrevLiveGroups: [String: ActionGroup]
}

// MARK: - RunnerStore thin wrappers

// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.
extension RunnerStore {

    func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                var jobs: [ActiveJob] = []
                for scope in ScopeStore.shared.scopes {
                    jobs.append(contentsOf: fetchActiveJobs(for: scope))
                }
                return jobs
            },
            backfill: { cache in
                backfillSteps(into: &cache)
            }
        )
    }

    func buildGroupState(
        snapPrevGroups: [String: ActionGroup],
        snapGroupCache: [String: ActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            jobCache: jobCache,
            fetchGroups: { shaKeyedCache in
                var groups: [ActionGroup] = []
                for scope in ScopeStore.shared.scopes {
                    groups.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedCache))
                }
                return groups
            },
            scopeFromGroup: { group in scopeFromActionGroup(group) },
            fireFailureHook: { group, scope in
                FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "pollResultBuilder")
            },
            enrichJobs: { jobs in enrichGroupJobs(jobs, jobCache: jobCache) }
        )
    }

    // MARK: - Backfill (retains ghAPI access via RunnerStore)

    func backfillSteps(into cache: inout [Int: ActiveJob]) {
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

    // MARK: - Group helpers (retain RunnerStore context)

    func scopeFromActionGroup(_ group: ActionGroup) -> String {
        log("RunnerStore › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)")
        if !group.repo.isEmpty {
            log("RunnerStore › scopeFromActionGroup — using group.repo='\(group.repo)'")
            return group.repo
        }
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

    func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasMoreSteps  = cached.steps.count > job.steps.count
            return (cacheHasConclusion || cacheHasMoreSteps) ? cached : job
        }
    }
}
