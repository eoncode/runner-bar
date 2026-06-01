// RunnerPollState.swift
// RunnerBar
import Foundation
import os
import RunnerBarCore

// MARK: - RunnerStore thin wrappers

// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

/// A `@unchecked Sendable` wrapper around `ISO8601DateFormatter`.
///
/// `ISO8601DateFormatter` is expensive to allocate (it loads ICU calendars on init).
/// Keeping one file-level instance avoids repeated allocation on every poll cycle.
/// Access is serialised via `iso8601Lock`; the `@unchecked` annotation is safe because
/// no two threads ever call the formatter concurrently.
private struct SendableFormatter: @unchecked Sendable {
    /// The internal formatter instance. Access only while holding `iso8601Lock`.
    let iso = ISO8601DateFormatter()
}

/// `OSAllocatedUnfairLock` protecting the shared `SendableFormatter`.
/// Always access the formatter via `iso8601Lock.withLock { ... }` to avoid data races.
private let iso8601Lock = OSAllocatedUnfairLock(initialState: SendableFormatter())

/// `RunnerStore` extension that bridges `PollResultBuilder` for the `fetch()` call sites.
///
/// All methods are `nonisolated` because polling runs on a background thread.
/// They read `ScopeStore.shared.scopes` via `DispatchQueue.main.sync` — this is safe
/// only when called from a background thread. Do not call these methods from the main thread
/// as `main.sync` from the main thread will deadlock.
extension RunnerStore {

    /// Builds a `JobPollResult` by fetching live jobs for all monitored scopes,
    /// backfilling step data from the cache, and diffing against `snapPrev`.
    nonisolated func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                // ⚠️ main.sync — safe only from a background thread; deadlocks if called on main.
                let scopes = DispatchQueue.main.sync { ScopeStore.shared.scopes }
                var jobs: [ActiveJob] = []
                for scope in scopes {
                    jobs.append(contentsOf: fetchActiveJobs(for: scope))
                }
                return jobs
            },
            backfill: { cache in
                self.backfillSteps(into: &cache)
            }
        )
    }

    /// Builds a `GroupPollResult` by fetching live workflow action groups for all monitored scopes,
    /// firing failure hooks for newly-failed groups, enriching jobs from the job cache,
    /// and diffing against `snapPrevGroups`.
    nonisolated func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        snapSeenGroupIDs: Set<String>,
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            fetchGroups: { shaKeyedCache in
                // ⚠️ main.sync — safe only from a background thread; deadlocks if called on main.
                let scopes = DispatchQueue.main.sync { ScopeStore.shared.scopes }
                var groups: [WorkflowActionGroup] = []
                for scope in scopes {
                    groups.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedCache))
                }
                return groups
            },
            scopeFromGroup: { group in self.scopeFromActionGroup(group) },
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
    nonisolated func backfillSteps(into cache: inout [Int: ActiveJob]) {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil,
                  cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                  !fresh.steps.isEmpty
            else { continue }
            cache[cacheID] = iso8601Lock.withLock { wrapper in
                makeActiveJob(from: fresh, iso: wrapper.iso, isDimmed: true)
            }
        }
    }

    // MARK: - Group helpers (retain RunnerStore context)

    /// Derives a scope string for `group` by first trying `group.repo`, then falling back
    /// to parsing the `htmlUrl` of the first run. Returns an empty string if neither is available.
    nonisolated func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
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

    /// Merges live job data with cached job data, preferring whichever has a conclusion
    /// or more complete step information.
    nonisolated func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasMoreSteps  = cached.steps.count > job.steps.count
            return (cacheHasConclusion || cacheHasMoreSteps) ? cached : job
        }
    }
}
