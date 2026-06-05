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
//   3. Build a name → APIRunnerPayload dictionary per scope.
//   4. Second pass: apply enrichment from the dictionary.
//
// Scope fetches run concurrently via withTaskGroup — poll latency is bounded
// by the slowest scope rather than the sum of all scopes.
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
/// Batches API calls by unique scope URL so a fleet of N runners registered to
/// the same repo/org issues only one API call per scope per poll cycle.
/// Multiple scopes are fetched concurrently via `withTaskGroup`.
///
/// - SeeAlso: `RunnerModel`, `RunnerStatus`, `LocalRunnerStore`
public struct RunnerStatusEnricher: Sendable {
    // MARK: - Shared singleton
    /// The shared enricher instance.
    public static let shared = RunnerStatusEnricher()
    /// Creates a new enricher instance.
    public init() { }

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
        // Use [APIRunnerPayload] (Sendable) rather than [[String: Any]] (not Sendable)
        // so the task-group result type satisfies Swift 6 strict concurrency.
        var nameToAPI: [String: APIRunnerPayload] = [:]
        await withTaskGroup(of: [APIRunnerPayload].self) { group in
            for scopeURL in scopeToRunnerIndices.keys {
                group.addTask { await self.fetchRunnersForScope(scopeURL) }
            }
            for await fetched in group {
                for payload in fetched {
                    nameToAPI[payload.name] = payload
                }
            }
        }

        // Step 3: apply enrichment in a second pass.
        var result = runners
        for idx in result.indices {
            let name = result[idx].runnerName
            if let api = nameToAPI[name] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            let nameLower = name.lowercased()
            if let key = nameToAPI.keys.first(where: { $0.lowercased() == nameLower }),
               let api = nameToAPI[key] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
            if let key = nameToAPI.keys.first(where: { $0.trimmingCharacters(in: .whitespaces) == nameTrimmed }),
               let api = nameToAPI[key] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            log("[Enricher] NO MATCH for '\(name)' — available API names: \(nameToAPI.keys.sorted()) gitHubUrl=\(result[idx].gitHubUrl ?? \"NIL\")")
        }
        return result
    }

    // MARK: - Private

    /// Fetches the complete runner list for a scope URL via ghAPI, paginating
    /// through all pages (per_page=100) until exhausted.
    private func fetchRunnersForScope(_ scopeURL: String) async -> [APIRunnerPayload] {
        let stripped = scopeURL.replacingOccurrences(of: GitHubConstants.base + "/", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }

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

    /// Applies enrichment data from an `APIRunnerPayload` to a `RunnerModel`.
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
