// RunnerStatusEnricher.swift
// RunnerBarCore
//
// Enriches a list of RunnerModel values with GitHub API data (status, busy, labels, group).
//
// Strategy: batch by unique scope URL.
//   1. Group runners by their gitHubUrl scope (repo or org).
//   2. Issue ONE ghAPI call per unique scope — not one call per runner.
//      Pages through all results (per_page=100) so fleets larger than
//      GitHub's default page size of 30 are fully covered.
//   3. Build a scopeURL → (name → APIRunnerPayload) dictionary per scope.
//   4. Second pass: apply enrichment from the dictionary, scoped by gitHubUrl.
//
// Scope fetches run concurrently via withTaskGroup — poll latency is bounded
// by the slowest scope rather than the sum of all scopes.
//
// NOTE: fetchRunnersForScope decodes the API response via JSONSerialization
// rather than casting directly — a direct `as? [String: Any]` cast from Data? always
// fails at runtime because Data and Dictionary are unrelated types.
//
// NOTE: fetchRunnersForScope intentionally does NOT check ghIsRateLimited before
// calling ghAPI. The transport layer (GitHubURLSessionTransport) is the single
// source of truth for rate-limit state. A permission 403 on an org-scope endpoint
// must NOT prevent a subsequent repo-scope fetch from running — the two scopes use
// independent API paths and may have different token permissions.
//
// See: RunnerModel, RunnerStatus
import Foundation

// MARK: - Codable payload

/// Minimal `Sendable` representation of a single runner object returned by the
/// GitHub `/actions/runners` API endpoint.
///
/// Using a typed struct instead of `[String: Any]` lets `withTaskGroup` cross
/// concurrency boundaries safely — `Any` does not conform to `Sendable`.
private struct APIRunnerPayload: Sendable {
    /// The GitHub REST API numeric runner ID for this runner.
    ///
    /// This is the `id` field returned by `/repos/{owner}/{repo}/actions/runners`
    /// and `/orgs/{org}/actions/runners`. It is stored on `RunnerModel.apiId` after
    /// enrichment so that `RunnerStore.buildInstallPathMap` can build a `byApiId`
    /// lookup map — enabling metrics resolution for org runners whose local
    /// `.runner` JSON `AgentId` differs from this GitHub-assigned id.
    let apiId: Int?
    /// The runner's display name as registered with GitHub.
    let name: String
    /// The runner's online/offline status string (e.g. `"online"`, `"offline"`).
    let status: String?
    /// Whether the runner is currently executing a job.
    let busy: Bool
    /// The runner group name the runner belongs to, if any.
    let runnerGroupName: String?
    /// The label names attached to this runner.
    let labelNames: [String]

    /// Decodes an `APIRunnerPayload` from a raw JSON dictionary produced by
    /// `JSONSerialization`. Returns `nil` if the required `name` key is absent.
    /// - Parameter dict: A `[String: Any]` dictionary from the GitHub API response.
    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String else { return nil }
        self.name = name
        self.apiId = dict["id"] as? Int
        self.status = dict["status"] as? String
        self.busy = dict["busy"] as? Bool ?? false
        self.runnerGroupName = dict["runner_group_name"] as? String
        self.labelNames = (dict["labels"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
    }
}

// MARK: - RunnerStatusEnricher

/// Enriches a `[RunnerModel]` snapshot with live GitHub API data.
///
/// Multiple scopes are fetched concurrently via `withTaskGroup`.
///
/// - Important: All methods are async. Always call from an async context —
///   never block the main actor waiting for enrichment.
/// - SeeAlso: `RunnerModel`, `RunnerStatus`, `LocalRunnerStore`
public struct RunnerStatusEnricher: Sendable {
    // MARK: - Shared singleton
    /// The shared `RunnerStatusEnricher` instance used throughout the app.
    public static let shared = RunnerStatusEnricher()

    /// Creates a new `RunnerStatusEnricher` instance.
    public init() { /* No setup required; all enrichment work is stateless. */ }

    /// Enriches `runners` with GitHub API status, busy flag, labels, and runner group.
    ///
    /// - Parameter runners: The locally-discovered runner list to enrich.
    /// - Returns: A new array with the same runners, each enriched where an API match was found.
    /// - Note: Runners whose `gitHubUrl` is `nil` are skipped and returned unchanged.
    public func enrich(runners: [RunnerModel]) async -> [RunnerModel] {
        // Step 1: collect unique scope URLs and the runners belonging to each.
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard let url = runner.gitHubUrl else {
                log("[Enricher] SKIP '\(runner.runnerName)' — gitHubUrl is nil")
                continue
            }
            scopeToRunnerIndices[url, default: []].append(idx)
        }

        // Step 2: fetch all scopes concurrently.
        // Use (scopeURL, [APIRunnerPayload]) tuples so results stay scope-keyed.
        // Keying by (scopeURL, name) prevents last-write-wins collisions when two
        // scopes (e.g. org + repo) expose a runner with the same registered name.
        var apiByScope: [String: [String: APIRunnerPayload]] = [:]
        await withTaskGroup(of: (String, [APIRunnerPayload]).self) { group in
            for scopeURL in scopeToRunnerIndices.keys {
                group.addTask { (scopeURL, await self.fetchRunnersForScope(scopeURL)) }
            }
            for await (scopeURL, fetched) in group {
                apiByScope[scopeURL] = Dictionary(
                    fetched.map { ($0.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }

        // Step 3: apply enrichment in a second pass.
        // `fallbackAPI` is hoisted outside the loop — `apiByScope` is immutable
        // after Step 2, so recomputing the merged dict on every iteration is O(N×S)
        // work for no benefit. Compute once here: O(S × runners-per-scope).
        //
        // Collision note: when two scopes expose a runner with the same registered
        // name AND that runner's gitHubUrl is nil (so the scoped lookup misses),
        // the fallback dict's `first` wins. The winner is the first scope whose
        // withTaskGroup task completes — non-deterministic but harmless in practice
        // since both payloads describe the same physical runner. A warning is logged
        // so collisions are visible in diagnostic output without any code change needed.
        var seenInFallback: [String: String] = [:]  // name → first winning scopeURL
        let fallbackAPI = apiByScope.reduce(into: [String: APIRunnerPayload]()) { result, entry in
            let (scopeURL, scopeDict) = entry
            for (name, payload) in scopeDict {
                if result[name] != nil {
                    log("[Enricher] ⚠️ fallback collision: runner '\(name)' appears in both '\(seenInFallback[name] ?? "?")' and '\(scopeURL)' — first-writer wins")
                } else {
                    result[name] = payload
                    seenInFallback[name] = scopeURL
                }
            }
        }
        var result = runners
        for idx in result.indices {
            let name = result[idx].runnerName
            // Restrict lookup to the runner's own scope first to avoid cross-scope
            // name collisions, then fall back to a scan across all scopes.
            let scopedAPI = result[idx].gitHubUrl.flatMap { apiByScope[$0] } ?? [:]

            func findPayload(in dict: [String: APIRunnerPayload]) -> APIRunnerPayload? {
                if let api = dict[name] { return api }
                let nameLower = name.lowercased()
                if let key = dict.keys.first(where: { $0.lowercased() == nameLower }) { return dict[key] }
                let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
                if let key = dict.keys.first(where: { $0.trimmingCharacters(in: .whitespaces) == nameTrimmed }) { return dict[key] }
                return nil
            }

            if let api = findPayload(in: scopedAPI) ?? findPayload(in: fallbackAPI) {
                result[idx] = applyEnrichment(to: result[idx], from: api)
            } else {
                let gitHubUrl = result[idx].gitHubUrl ?? "NIL"
                log("[Enricher] NO MATCH for '\(name)' — available API names: \(scopedAPI.keys.sorted()) gitHubUrl=\(gitHubUrl)")
            }
        }
        return result
    }

    // MARK: - Private

    /// Fetches the **complete** runner list for a scope URL via ghAPI, paginating
    /// through all pages (per_page=100) until exhausted.
    ///
    /// - Parameter scopeURL: The full GitHub URL for the repo or org scope.
    /// - Returns: All runner payloads collected across all pages. Empty on failure.
    ///
    /// GitHub's default page size is 30. Without explicit pagination any org/repo
    /// with more than 30 runners would silently lose enrichment for runners beyond
    /// the first page. Using per_page=100 (the API maximum) minimises round-trips.
    ///
    /// - Note: This method intentionally does NOT gate on `ghIsRateLimited`. A permission
    ///   403 on one scope (e.g. org) must not block a repo-scope fetch from running.
    ///   The transport layer handles real rate-limits; duplicating the check here causes
    ///   false skips when scopes are fetched concurrently and an org 403 fires first.
    private func fetchRunnersForScope(_ scopeURL: String) async -> [APIRunnerPayload] {
        let stripped = scopeURL.replacingOccurrences(of: GitHubConstants.base + "/", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
        let baseEndpoint: String
        if parts.count >= 2 {
            baseEndpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
        } else {
            baseEndpoint = "orgs/\(parts[0])/actions/runners"
        }

        var allRunners: [APIRunnerPayload] = []
        var page = 1
        let perPage = 100

        while true {
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"
            guard let data = await ghAPI(endpoint),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — ghAPI returned nil or JSON parse failed")
                break
            }
            let totalCount = json["total_count"] as? Int ?? -1
            guard let pageRunners = json["runners"] as? [[String: Any]] else {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — 'runners' key missing. total_count=\(totalCount)")
                break
            }
            log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) returned \(pageRunners.count) runners (total_count=\(totalCount))")
            allRunners.append(contentsOf: pageRunners.compactMap { APIRunnerPayload(dict: $0) })
            guard pageRunners.count == perPage else { break }
            page += 1
        }

        log("[Enricher] fetchRunnersForScope \(scopeURL) total collected \(allRunners.count) runners")
        return allRunners
    }

    /// Applies fields from an `APIRunnerPayload` to a `RunnerModel`.
    ///
    /// - Returns: A new `RunnerModel` with API-sourced fields applied.
    /// - Note: Platform and architecture are derived from API labels when the `.runner`
    ///   JSON on disk did not supply them (older runner agent versions omit these fields).
    ///   Prefer label-derived values (always correctly cased by GitHub)
    ///   over whatever `.runner` JSON provided (often nil or raw OS strings).
    private func applyEnrichment(to runner: RunnerModel, from api: APIRunnerPayload) -> RunnerModel {
        let githubStatus = api.status.map { RunnerStatus(rawString: $0) }
        let effectiveLabels = api.labelNames.isEmpty ? runner.labels : api.labelNames
        let labelPlatform = effectiveLabels.first(where: { label in
            let l = label.lowercased()
            return l == "macos" || l == "linux" || l == "windows"
        })
        let labelArch = effectiveLabels.first(where: { label in
            let l = label.lowercased()
            return l == "arm64" || l == "x64" || l == "x86" || l == "aarch64"
        })
        let platform = labelPlatform ?? runner.platform
        let platformArchitecture = labelArch ?? runner.platformArchitecture

        return RunnerModel(
            id: runner.id,
            runnerName: runner.runnerName,
            gitHubUrl: runner.gitHubUrl,
            agentId: runner.agentId,
            apiId: api.apiId,
            workFolder: runner.workFolder,
            installPath: runner.installPath,
            isRunning: runner.isRunning,
            labels: effectiveLabels,
            githubStatus: githubStatus,
            isBusy: api.busy,
            lifecycleWarning: runner.lifecycleWarning,
            platform: platform,
            platformArchitecture: platformArchitecture,
            agentVersion: runner.agentVersion,
            isEphemeral: runner.isEphemeral,
            runnerGroup: api.runnerGroupName,
            metrics: runner.metrics
        )
    }
}
