// swiftlint:disable function_parameter_count type_body_length
import Foundation

// MARK: - RunnerStatusEnricher
//
// Enriches a list of RunnerModel values with GitHub API data (status, busy, labels, group).
//
// Strategy: batch by unique scope URL.
//   1. Group runners by their gitHubUrl scope (repo or org).
//   2. Issue ONE ghAPI call per unique scope — not one call per runner.
//   3. Build a name → APIRunner dictionary per scope.
//   4. Second pass: apply enrichment from the dictionary.
//
// This preserves the original 1–2 API-calls-per-poll-cycle behaviour and routes
// through ghAPI so ghIsRateLimited is honoured and the gh-CLI fallback is available.
//
// NOTE: ghAPI returns Data?. fetchRunnersForScope decodes it via JSONSerialization
// rather than casting directly — a direct `as? [String: Any]` cast from Data? always
// fails at runtime because Data and Dictionary are unrelated types.

final class RunnerStatusEnricher: @unchecked Sendable {
    static let shared = RunnerStatusEnricher()
    private init() {}

    func enrich(runners: [RunnerModel]) -> [RunnerModel] {
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

    /// Fetches the full runner list for a scope URL via ghAPI (respects ghIsRateLimited).
    /// Returns an empty array on failure or when rate-limited.
    private func fetchRunnersForScope(_ scopeURL: String) -> [[String: Any]] {
        guard !ghIsRateLimited else { return [] }

        let parts = scopeURL
            .replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard !parts.isEmpty else { return [] }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
        // All other callers use "repos/…" or "orgs/…" without a leading "/".
        let endpoint: String
        if parts.count >= 2 {
            endpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
        } else {
            endpoint = "orgs/\(parts[0])/actions/runners"
        }

        // ghAPI returns Data?; decode via JSONSerialization before casting.
        guard let data = ghAPI(endpoint),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runners = json["runners"] as? [[String: Any]] else { return [] }
        return runners
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
