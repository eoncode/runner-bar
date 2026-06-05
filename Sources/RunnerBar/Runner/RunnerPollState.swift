// RunnerPollState.swift
// RunnerBar
import Foundation
import os
import RunnerBarCore

// MARK: - DateParserActor

/// Actor-isolated ISO-8601 date parser.
///
/// `ISO8601DateFormatter` is expensive to allocate (it loads ICU calendars on init).
/// Keeping one file-level instance avoids repeated allocation on every poll cycle.
/// Wrapping it in an actor gives thread-safe access with no lock
/// boilerplate and no `@unchecked Sendable` escape hatch.
private actor DateParserActor {
    private let iso = ISO8601DateFormatter()
    func parse(_ str: String) -> Date? { iso.date(from: str) }
    func makeJob(from payload: JobPayload, isDimmed: Bool) -> ActiveJob {
        makeActiveJob(from: payload, iso: iso, isDimmed: isDimmed)
    }
}

private let dateParser = DateParserActor()

// MARK: - RunnerStore thin wrappers

// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

/// `RunnerStore` extension that bridges `PollResultBuilder` for the `fetch()` call sites.
extension RunnerStore {

    /// Builds a `JobPollResult` by fetching live jobs for all monitored scopes,
    /// backfilling step data from the cache, and diffing against `snapPrev`.
    func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) async -> JobPollResult {
        await PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                let scopes = await MainActor.run { ScopeStore.shared.scopes }
                var jobs: [ActiveJob] = []
                for scope in scopes {
                    jobs.append(contentsOf: await fetchActiveJobs(for: scope))
                }
                return jobs
            },
            backfill: { cache in
                await self.backfillSteps(into: &cache)
            }
        )
    }

    /// Builds a `GroupPollResult` by fetching live workflow action groups for all monitored scopes,
    /// firing failure hooks for newly-failed groups, enriching jobs from the job cache,
    /// and diffing against `snapPrevGroups`.
    func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        snapSeenGroupIDs: Set<String>,
        jobCache: [Int: ActiveJob]
    ) async -> GroupPollResult {
        await PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            fetchGroups: { shaKeyedCache in
                let scopes = await MainActor.run { ScopeStore.shared.scopes }
                var groups: [WorkflowActionGroup] = []
                for scope in scopes {
                    groups.append(contentsOf: await fetchActionGroups(for: scope, cache: shaKeyedCache))
                }
                return groups
            },
            scopeFromGroup: { group in
                await MainActor.run { self.scopeFromActionGroup(group) }
            },
            fireFailureHook: { group, scope in
                FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "pollResultBuilder")
            },
            enrichJobs: { jobs in self.enrichGroupJobs(jobs, jobCache: jobCache) }
        )
    }

    // MARK: - Backfill (retains ghAPI access via RunnerStore)

    /// Backfills step data for cached jobs that finished without complete step information.
    ///
    /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
    /// fetches the full job payload from the GitHub API, and updates the cache entry.
    func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                  !fresh.steps.isEmpty
            else { continue }
            cache[cacheID] = await dateParser.makeJob(from: fresh, isDimmed: true)
        }
    }

    // MARK: - Group helpers

    @MainActor
    func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
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
        log("RunnerStore › scopeFromActionGroup — could not derive scope, returning empty string! groupID=\(group.id)")
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
