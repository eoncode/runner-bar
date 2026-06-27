// RunnerPoller+Backfill.swift
// RunnerBarCore

import Foundation

// MARK: - RunnerPoller: step backfill

/// Helpers for backfilling step data into completed-job cache entries.
extension RunnerPoller {

  /// Backfills step data into the completed-job cache.
  ///
  /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
  /// fetches the full job payload from the GitHub API, and updates the cache entry.
  ///
  /// **Eviction rationale — these are NOT data-loss bugs:**
  /// Three categories of cache entry are evicted (via `removeValue`) rather than
  /// skipped or retried. Each is intentional and self-correcting:
  ///
  /// 1. **`scope == nil` (pre-scope-injection entries)**
  ///    Written before scope-injection was introduced (pre-F-26). As of F-26,
  ///    `fetchAllJobs` always injects scope via `.copying(scope:)` at fetch time,
  ///    so `scope == nil` entries should only appear in the first poll cycle after
  ///    an upgrade from a pre-F-26 build. Evicting them prevents repeated per-poll
  ///    warning spam. They re-enter the cache with correct scope data on the next
  ///    poll cycle once a new live fetch completes. This flash is cosmetic and
  ///    self-corrects within one poll cycle.
  ///    TODO: Remove this guard after two release cycles once pre-F-26 cache
  ///    entries are definitively gone from the field.
  ///
  /// 2. **Org-only scope (`!scope.contains("/")`)**
  ///    The GitHub Jobs API has no `orgs/{org}/actions/jobs/{id}` endpoint — only
  ///    `repos/{owner}/{repo}/actions/jobs/{id}`. Keeping these entries would log a
  ///    warning every poll cycle with no path to ever resolve them. Eviction is a
  ///    one-time operation; the entry cannot re-populate via any backfill path
  ///    (no GitHub org/actions/jobs endpoint exists).
  ///
  /// 3. **Empty-steps API response**
  ///    Early-queued jobs may return zero steps transiently. The guard
  ///    `guard !updated.steps.isEmpty` keeps the existing cache entry unchanged and
  ///    retries on the next poll — this is a *skip*, not an eviction.
  ///
  /// The `removeValue` calls for cases 1 and 2 are therefore intentional, not data loss.
  func backfillSteps(into cache: inout [Int: ActiveJob]) async {
    for cacheID in Array(cache.keys) {
      guard let cached = cache[cacheID] else { continue }
      guard cached.conclusion != nil else { continue }
      guard cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress })
      else { continue }
      guard let scope = validRepoScope(for: cached, jobID: cacheID, cache: &cache) else { continue }
      guard let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)") else { continue }
      if let refreshed = await decodedBackfillJob(data, jobID: cacheID, existingScope: cached.scope) {
        cache[cacheID] = refreshed
      }
    }
  }

  /// Validates and returns the repo-scoped path for a cached job, evicting entries that
  /// lack a scope or carry an org-only scope (neither can be backfilled via the API).
  /// Returns `nil` in both eviction cases so the caller can `continue` immediately.
  private func validRepoScope(
    for job: ActiveJob,
    jobID: Int,
    cache: inout [Int: ActiveJob]
  ) -> String? {
    guard let scope = job.scope else {
      cache.removeValue(forKey: jobID)
      log(
        "RunnerPoller › backfillSteps — evicted jobID=\(jobID): scope is nil (pre-scope-injection entry)",
        category: .runner)
      return nil
    }
    guard scope.contains("/") else {
      cache.removeValue(forKey: jobID)
      log(
        "RunnerPoller › backfillSteps — evicted jobID=\(jobID): org-only scope '\(scope)' has no repo path; org-only jobs cannot be backfilled (no GitHub org/actions/jobs endpoint)",
        category: .runner)
      return nil
    }
    return scope
  }

  /// Decodes a raw API response into an `ActiveJob` for replacing a backfill cache entry.
  /// Restores the original scope (absent from the API payload) and guards against empty-steps
  /// responses that would clobber valid cached step data. Returns `nil` on failure or 0 steps.
  private func decodedBackfillJob(
    _ rawData: Data,
    jobID: Int,
    existingScope: String?
  ) async -> ActiveJob? {
    do {
      let payload = try decoder.decode(JobPayload.self, from: rawData)
      let updated = await ISO8601DateParser.shared.makeJob(from: payload, isDimmed: true)
      guard !updated.steps.isEmpty else {
        log(
          "RunnerPoller › backfillSteps — jobID=\(jobID) API returned 0 steps, keeping existing cache entry",
          category: .runner)
        return nil
      }
      return updated.copying(scope: existingScope)
    } catch {
      log(
        "RunnerPoller › backfillSteps — ⚠️ decode failed for jobID=\(jobID): \(error)",
        category: .runner)
      return nil
    }
  }
}
