// RunnerPollState.swift
// RunnerBar
import Foundation
import os
import RunnerBarCore

// MARK: - RunnerStore thin wrappers

// These extensions delegate to PollResultBuilder so RunnerStore.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

// Shared ISO-8601 date formatter for this file.
// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
// keeping one file-level instance avoids repeated allocation on every poll cycle.
// Safety: protected by iso8601Lock.

/// A Sendable wrapper for ISO8601DateFormatter.
private struct SendableFormatter: @unchecked Sendable {
    /// The internal formatter instance.
    let iso = ISO8601DateFormatter()
}
/// Lock for the formatter.
private let iso8601Lock = OSAllocatedUnfairLock(initialState: SendableFormatter())

/// Extension adding functionality to `RunnerStore`.
extension RunnerStore {

    /// Performs the buildJobState operation.
    nonisolated func buildJobState(snapPrev: [Int: ActiveJob], snapCache: [Int: ActiveJob]) -> JobPollResult {
        PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: {
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

    /// Performs the buildGroupState operation.
    nonisolated func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> GroupPollResult {
        PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            fetchGroups: { shaKeyedCache in
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

    /// Performs the backfillSteps operation.
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

    /// Performs the scopeFromActionGroup operation.
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

    /// Performs the enrichGroupJobs operation.
    nonisolated func enrichGroupJobs(_ jobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let cacheHasConclusion = cached.conclusion != nil && job.conclusion == nil
            let cacheHasMoreSteps  = cached.steps.count > job.steps.count
            return (cacheHasConclusion || cacheHasMoreSteps) ? cached : job
        }
    }
}
