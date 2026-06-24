// RunnerPoller+PollBridge.swift
// RunnerBarCore
//
// Step 10: Moved to RunnerBarCore as `extension RunnerPoller`.
// `FailureHookRunner` is decoupled — the injected `fireFailureHook` closure
// stored on `RunnerPoller` is the sole integration point, keeping
// `FailureHookRunner` in the app target and out of `RunnerBarCore`.
import Foundation
import os

// MARK: - RunnerPoller PollBridge

// These extensions delegate to PollResultBuilder so RunnerPoller.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

/// `RunnerPoller` extension that bridges `PollResultBuilder` for the `fetch()` call sites.
///
/// All methods are `async` and run off the main actor during `await` — the
/// cooperative thread pool handles network work, and the continuation returns
/// to `@MainActor` automatically after each `await`.
/// `await MainActor.run { }` replaces the old `DispatchQueue.main.sync` pattern;
/// unlike `main.sync`, `MainActor.run` is re-entrant-safe and will not deadlock
/// when called from the main actor itself.
///
/// `FailureHookRunner` is intentionally **not** referenced here — the
/// injected `fireFailureHook` closure on `RunnerPoller` is the sole integration
/// point, keeping `FailureHookRunner` in the app target and out of `RunnerBarCore`.
extension RunnerPoller {

    /// Builds a `JobPollResult` by fetching live jobs for all monitored scopes,
    /// backfilling step data from the cache, and diffing against `snapPrev`.
    public func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob]
    ) async -> JobPollResult {
        await PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                let scopes = await MainActor.run { self.scopeStore.activeScopes }
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
    public func buildGroupState(
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
                let scopes = await MainActor.run { self.scopeStore.activeScopes }
                var groups: [WorkflowActionGroup] = []
                for scope in scopes {
                    let fetched = await self.actionGroupFetcher.fetch(
                        for: scope,
                        cache: shaKeyedCache
                    )
                    groups.append(contentsOf: fetched)
                }
                return groups
            },
            scopeFromGroup: { group in
                self.scopeFromActionGroup(group)
            },
            fireFailureHook: { group, scope in
                // PollResultBuilder.buildGroupState (and freezeVanishedGroups) already
                // `await` this closure directly — no Task wrapper needed or correct here.
                // The hook runs inline on the cooperative thread pool as part of the
                // structured async chain that buildGroupState owns.
                // `fireFailureHook` is injected at init by the app layer so Core never
                // imports `FailureHookRunner`.
                await self.fireFailureHook(group, scope)
            },
            enrichJobs: { jobs in
                self.enrichGroupJobs(jobs, jobCache: jobCache)
            }
        )
    }

    /// Backfills step data into the completed-job cache.
    ///
    /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
    /// fetches the full job payload from the GitHub API, and updates the cache entry.
    /// Uses `decoder` — a stored instance property on `RunnerPoller` — which is serialised
    /// by the actor's own executor, ensuring no concurrent access.
    public func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? decoder.decode(JobPayload.self, from: data),
                  !fresh.steps.isEmpty
            else { continue }
            cache[cacheID] = await ISO8601DateParser.shared.makeJob(from: fresh, isDimmed: true)
        }
    }

    // MARK: - Group helpers

    /// Derives the scope string (repo or org URL) from a `WorkflowActionGroup`.
    ///
    /// `nonisolated`: reads only `group` (a `Sendable` value type passed as a parameter)
    /// and calls `scopeFromHtmlUrl` (a pure free function). No main-actor state is accessed,
    /// so the `@MainActor` hop at every call site in `buildGroupState` is unnecessary.
    public nonisolated func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
        log("RunnerPoller › scopeFromActionGroup — group.repo='\(group.repo)' groupID=\(group.id)")
        if !group.repo.isEmpty {
            log("RunnerPoller › scopeFromActionGroup — using group.repo='\(group.repo)'")
            return group.repo
        }
        log("RunnerPoller › scopeFromActionGroup — group.repo is empty, trying htmlUrl of first run")
        if let firstRun = group.runs.first,
           let url = firstRun.htmlUrl,
           let scope = scopeFromHtmlUrl(url) {
            log("RunnerPoller › scopeFromActionGroup — derived scope '\(scope)' from htmlUrl '\(url)'")
            return scope
        }
        log("RunnerPoller › scopeFromActionGroup — ⚠️ could not derive scope for groupID=\(group.id)")
        return ""
    }

    /// Enriches a group's job list with step and conclusion data from the job cache.
    ///
    /// `nonisolated`: pure map over `jobCache` (a value-type snapshot captured at the
    /// closure creation site) with no reads from `RunnerStore`'s actor-isolated state.
    /// Marking it `nonisolated` removes the implicit `@MainActor` hop that was serialising
    /// every `withTaskGroup` child task in `PollResultBuilder.buildGroupState` through
    /// the main actor, negating the intended parallelism (#1153).
    public nonisolated func enrichGroupJobs(
        _ jobs: [ActiveJob],
        jobCache: [Int: ActiveJob]
    ) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            // cacheHasConclusion: the cache settled a conclusion the live API hasn't returned
            // yet (common on the first poll after a job finishes — GitHub propagates conclusion
            // slightly after status flips to "completed").
            //
            // cacheHasBetterSteps: the cache has fully-resolved steps while the live payload
            // still shows in-progress ones (backfill ran after the main fetch).
            //
            // When only cacheHasConclusion fires (cacheHasBetterSteps is false), the merged
            // job carries conclusion from the cache and steps from the live job. This is
            // intentional: the live steps are the freshest available data; showing them
            // alongside a bridged conclusion is correct. Returning the full stale cached
            // entry would hide newer step state. The `steps` field in the UI only renders
            // the step list when the job is expanded, so a brief one-poll transient where
            // conclusion is set but steps are still completing is acceptable and preferable
            // to stale data. This is NOT a conclusion/steps inconsistency bug.
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
