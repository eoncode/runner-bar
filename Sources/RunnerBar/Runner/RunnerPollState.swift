// RunnerPollState.swift
// RunnerBar
import Combine
import Foundation
import os
import RunnerBarCore

// MARK: - RunnerStore thin wrappers

// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

/// `RunnerStore` extension that bridges `PollResultBuilder` for the `fetch()` call sites.
///
/// All methods are `async` and run off the main actor during `await` — the
/// cooperative thread pool handles network work, and the continuation returns
/// to `@MainActor` automatically after each `await`. The previous
/// `DispatchQueue.main.sync` pattern (which could deadlock if called on the
/// main thread) has been replaced throughout with `await MainActor.run { }`.
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
            enrichJobs: { jobs in
                await MainActor.run { self.enrichGroupJobs(jobs, jobCache: jobCache) }
            }
        )
    }

    /// Backfills step data into the completed-job cache.
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
            cache[cacheID] = await ISO8601DateParser.shared.makeJob(from: fresh, isDimmed: true)
        }
    }

    // MARK: - Group helpers

    /// Derives the scope string (repo or org URL) from a `WorkflowActionGroup`.
    @MainActor
    func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
        log("RunnerStore › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)")
        if !group.repo.isEmpty {
            log("RunnerStore › scopeFromActionGroup — using group.repo='\(group.repo)'")
            return group.repo
        }
        log("RunnerStore › scopeFromActionGroup — group.repo is empty, trying htmlUrl of first run")
        if let firstRun = group.runs.first,
           let url = firstRun.htmlUrl,
           let scope = scopeFromHtmlUrl(url) {
            log("RunnerStore › scopeFromActionGroup — derived scope '\(scope)' from htmlUrl '\(url)'")
            return scope
        }
        log("RunnerStore › scopeFromActionGroup — ⚠️ could not derive scope for groupID=\(group.id)")
        return ""
    }

    /// Enriches a group's job list with step and conclusion data from the job cache.
    func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasBetterSteps = !cached.steps.isEmpty
                && (job.steps.isEmpty || job.steps.contains { $0.status == .inProgress })
                && !cached.steps.contains { $0.status == .inProgress }
            guard cacheHasConclusion || cacheHasBetterSteps else { return job }
            return ActiveJob(
                id: job.id,
                name: job.name,
                htmlUrl: job.htmlUrl,
                status: job.status,
                conclusion: cached.conclusion ?? job.conclusion,
                isDimmed: job.isDimmed,
                runnerName: job.runnerName,
                scope: job.scope,
                startedAt: job.startedAt,
                completedAt: cached.completedAt ?? job.completedAt,
                steps: cacheHasBetterSteps ? cached.steps : job.steps
            )
        }
    }
}
