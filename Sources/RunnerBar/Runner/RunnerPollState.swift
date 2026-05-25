// RunnerPollState.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerStore poll-cycle helpers

/// Shared ISO-8601 date formatter used by the poll-cycle helpers below.
private let iso8601 = ISO8601DateFormatter()

/// Extension on `RunnerStore` providing poll-cycle helpers that delegate
/// to `PollResultBuilder` for independently testable build logic.
extension RunnerStore {
    /// Builds the job-poll state by fetching live jobs for all scopes and backfilling concluded jobs.
    nonisolated func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
                var jobs: [ActiveJob] = []
                for scope in ScopeStore.shared.scopes { jobs.append(contentsOf: fetchActiveJobs(for: scope)) }
                return jobs
            },
            backfill: { self.backfillSteps(into: &$0) }
        )
    }

    /// Builds the group-poll state by fetching workflow action groups and enriching their jobs.
    nonisolated func buildGroupState(snapPrevGroups: [String: WorkflowActionGroup], snapGroupCache: [String: WorkflowActionGroup], jobCache: [Int: ActiveJob]) -> GroupPollResult {
        PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            fetchGroups: {
                var groups: [WorkflowActionGroup] = []
                for scope in ScopeStore.shared.scopes { groups.append(contentsOf: fetchActionGroups(for: scope, cache: $0)) }
                return groups
            },
            scopeFromGroup: { self.scopeFromActionGroup($0) },
            fireFailureHook: { FailureHookRunner.fireIfNeeded(group: $0, scope: $1, callsite: "pollResultBuilder") },
            enrichJobs: { self.enrichGroupJobs($0, jobCache: jobCache) }
        )
    }

    /// Backfills missing step data for concluded jobs in `cache` by re-fetching from the GitHub API.
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
            cache[cacheID] = makeActiveJob(from: fresh, iso: iso8601, isDimmed: true)
        }
    }

    /// Returns the "owner/repo" scope string for a workflow action group.
    nonisolated func scopeFromActionGroup(_ group: WorkflowActionGroup) -> String {
        if !group.repo.isEmpty { return group.repo }
        if let firstRun = group.runs.first, let url = firstRun.htmlUrl, let derived = scopeFromHtmlUrl(url) { return derived }
        return ""
    }

    /// Merges enriched job data from `jobCache` into `jobs`, preferring cached entries with more data.
    nonisolated func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            return (cached.conclusion != nil && job.conclusion == nil) || cached.steps.count > job.steps.count ? cached : job
        }
    }
}
