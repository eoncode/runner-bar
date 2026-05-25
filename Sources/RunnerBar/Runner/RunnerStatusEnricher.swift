// RunnerStatusEnricher.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerStatusEnricher

/// Enriches a list of `RunnerModel` values with live GitHub API data
/// (status, busy, labels, runner group).
///
/// **Strategy — batch by unique scope URL:**
/// 1. Group runners by their `gitHubUrl` scope (repo or org).
/// 2. Issue **one** `ghAPI` call per unique scope — not one call per runner.
///    Pages through all results (`per_page=100`) so fleets larger than
///    GitHub’s default page size of 30 are fully covered.
/// 3. Build a `name → APIRunner` dictionary per scope.
/// 4. Second pass: apply enrichment from the dictionary.
///
/// All methods are synchronous and blocking — always call from a background thread.
struct RunnerStatusEnricher {

    // MARK: - Shared singleton

    /// The shared `RunnerStatusEnricher` instance used throughout the app.
    static let shared = RunnerStatusEnricher()

    // MARK: - Public API

    /// Enriches `runners` with live GitHub API data and returns the updated array.
    func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        // Step 1: collect unique scope URLs and the runner indices belonging to each.
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard let url = runner.gitHubUrl else { continue }
            scopeToRunnerIndices[url, default: []].append(idx)
        }
        // Step 2: fetch the full runner list for each scope once.
        var nameToAPI: [String: [String: Any]] = [:]
        for scopeURL in scopeToRunnerIndices.keys {
            let fetched = fetchRunnersForScope(scopeURL)
            for apiRunner in fetched {
                if let name = apiRunner["name"] as? String { nameToAPI[name] = apiRunner }
            }
        }
        // Step 3: apply enrichment in a second pass.
        var result = runners
        for idx in result.indices {
            guard let api = nameToAPI[result[idx].runnerName] else { continue }
            result[idx] = applyEnrichment(to: result[idx], from: api)
        }
        return result
    }
}

// MARK: - Private helpers

/// Private helpers for `RunnerStatusEnricher`.
private extension RunnerStatusEnricher {

    /// Fetches the **complete** runner list for a scope URL via `ghAPI`, paginating
    /// through all pages (`per_page=100`) until exhausted.
    ///
    /// GitHub’s default page size is 30; without explicit pagination any org/repo
    /// with more than 30 runners would silently lose enrichment beyond the first page.
    ///
    /// - Parameter scopeURL: The GitHub HTML URL of the repo or org scope to query.
    /// - Returns: All raw runner dictionaries fetched from the API, or an empty array on failure.
    func fetchRunnersForScope(_ scopeURL: String) -> [[String: Any]] {
        guard !ghIsRateLimited else { return [] }
        let parts = scopeURL
            .replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard !parts.isEmpty else { return [] }
        let baseEndpoint: String
        if parts.count >= 2 {
            baseEndpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
        } else {
            baseEndpoint = "orgs/\(parts[0])/actions/runners"
        }
        var allRunners: [[String: Any]] = []
        var page = 1
        let perPage = 100
        repeat {
            guard !ghIsRateLimited else { break }
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"
            guard let data = ghAPI(endpoint),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageRunners = json["runners"] as? [[String: Any]]
            else { break }
            allRunners.append(contentsOf: pageRunners)
            guard pageRunners.count == perPage else { break }
            page += 1
        } while true
        return allRunners
    }

    /// Applies fields from a raw GitHub API runner dictionary to a `RunnerModel`,
    /// returning a new model with updated status, busy flag, labels, and runner group.
    ///
    /// - Parameters:
    ///   - runner: The existing `RunnerModel` to enrich.
    ///   - api: Raw dictionary from the GitHub Runners REST API.
    /// - Returns: A new `RunnerModel` with enriched fields merged in.
    func applyEnrichment(to runner: RunnerModel, from api: [String: Any]) -> RunnerModel {
        let status = api["status"] as? String
        let busy = api["busy"] as? Bool ?? false
        let group = api["runner_group_name"] as? String
        let labelNames = (api["labels"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        return RunnerModel(
            id: runner.id,
            runnerName: runner.runnerName,
            gitHubUrl: runner.gitHubUrl,
            agentId: runner.agentId,
            workFolder: runner.workFolder,
            installPath: runner.installPath,
            isRunning: runner.isRunning,
            labels: labelNames.isEmpty ? runner.labels : labelNames,
            githubStatus: status,
            isBusy: busy,
            lifecycleWarning: runner.lifecycleWarning,
            platform: runner.platform,
            platformArchitecture: runner.platformArchitecture,
            agentVersion: runner.agentVersion,
            isEphemeral: runner.isEphemeral,
            runnerGroup: group,
            metrics: runner.metrics
        )
    }
}
