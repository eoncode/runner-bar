// RunnerStatusEnricher.swift
// RunnerBarCore
// swiftlint:disable function_parameter_count type_body_length
import Foundation

// MARK: - RunnerStatusEnricher
//
// Enriches a list of RunnerModel values with GitHub API data (status, busy, labels, group).
//
// Strategy: batch by unique scope URL.
//   1. Group runners by their gitHubUrl scope (repo or org).
//   2. Issue ONE ghAPI call per unique scope — not one call per runner.
//      Pages through all results (per_page=100) so fleets larger than
//      GitHub's default page size of 30 are fully covered.
//   3. Build a name → APIRunner dictionary per scope.
//   4. Second pass: apply enrichment from the dictionary.
//
// This preserves the original 1–N API-calls-per-poll-cycle behaviour and routes
// through ghAPI so ghIsRateLimited is honoured and the gh-CLI fallback is available.
//
// NOTE: ghAPI returns Data?. fetchRunnersForScope decodes it via JSONSerialization
// rather than casting directly — a direct `as? [String: Any]` cast from Data? always
// fails at runtime because Data and Dictionary are unrelated types.
//
// All methods are synchronous and blocking — always call from a background thread.
/// A value type representing RunnerStatusEnricher.
public struct RunnerStatusEnricher: Sendable {
    // MARK: - Shared singleton

    // The shared `RunnerStatusEnricher` instance used throughout the app.
    // Declared as a static let on the struct for convenient access; callers
    // may also construct a local instance (e.g. in tests) without side effects.
    /// The shared constant.
    public static let shared = RunnerStatusEnricher()

    /// Public memberwise initialiser.
    public init() {}

    /// Performs the enrich operation.
    public func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        // Step 1: collect unique scope URLs and the runners belonging to each.
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard let url = runner.gitHubUrl else { continue }
            scopeToRunnerIndices[url, default: []].append(idx)
        }

        // Step 2: fetch the full runner list for each scope once.
        // Key: runnerName, Value: raw API dictionary.
        var nameToAPI: [String: [String: Any]] = [:]
        for scopeURL in scopeToRunnerIndices.keys {
            let fetched = fetchRunnersForScope(scopeURL)
            for apiRunner in fetched {
                if let name = apiRunner["name"] as? String {
                    nameToAPI[name] = apiRunner
                }
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

    // MARK: - Private

    /// Fetches the **complete** runner list for a scope URL via ghAPI, paginating
    /// through all pages (per_page=100) until exhausted.
    /// Returns an empty array on failure or when rate-limited.
    ///
    /// GitHub's default page size is 30. Without explicit pagination any org/repo
    /// with more than 30 runners would silently lose enrichment for runners beyond
    /// the first page. Using per_page=100 (the API maximum) minimises round-trips.
    private func fetchRunnersForScope(_ scopeURL: String) -> [[String: Any]] {
        guard !ghIsRateLimited else { return [] }

        let parts = scopeURL
            .replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard !parts.isEmpty else { return [] }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
        // All other callers use "repos/…" or "orgs/…" without a leading "/".
        let baseEndpoint: String
        if parts.count >= 2 {
            baseEndpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
        } else {
            baseEndpoint = "orgs/\(parts[0])/actions/runners"
        }

        // Paginate: request up to 100 runners per page until a page returns
        // fewer than the page size, indicating we've reached the last page.
        var allRunners: [[String: Any]] = []
        var page = 1
        let perPage = 100

        repeat {
            guard !ghIsRateLimited else { break }
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"

            // ghAPI returns Data?; decode via JSONSerialization before casting.
            guard let data = ghAPI(endpoint),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageRunners = json["runners"] as? [[String: Any]] else { break }

            allRunners.append(contentsOf: pageRunners)

            // If the page returned fewer runners than the page size we've
            // consumed all available runners — no need for another request.
            guard pageRunners.count == perPage else { break }
            page += 1
        } while true

        return allRunners
    }

    /// Applies fields from a raw GitHub API runner dictionary to a RunnerModel.
    private func applyEnrichment(to runner: RunnerModel, from api: [String: Any]) -> RunnerModel {
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
// swiftlint:enable function_parameter_count type_body_length
