import Foundation

// MARK: - RunnerStatusEnricher

/// Phase 4: Enriches locally-discovered `RunnerModel` values with live status
/// from the GitHub API.
///
/// Uses the `gitHubUrl` already stored in each runner to call only the targeted
/// API endpoints — no brute-force org/repo iteration. One API call per unique
/// scope (owner/repo or org) in the runner list.
///
/// All methods are synchronous and blocking — always call from a background thread.
struct RunnerStatusEnricher {
    // MARK: - Shared singleton

    static let shared = RunnerStatusEnricher()
    private init() {}

    // MARK: - Codable schema

    private struct APIRunner: Decodable {
        let id: Int
        let name: String
        let status: String      // "online" | "offline"
        let busy: Bool
    }

    private struct APIRunnersPage: Decodable {
        let runners: [APIRunner]
    }

    // MARK: - Public API

    /// Fetches live GitHub status for all runners whose `gitHubUrl` is known
    /// and returns a new array with `githubStatus` and `isBusy` populated.
    /// Runners without a `gitHubUrl` are returned unchanged.
    ///
    /// - Parameter runners: The array of `RunnerModel` values from Phase 1 scan.
    /// - Returns: Enriched copy of the input array.
    func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        guard !runners.isEmpty else { return runners }

        // Group runners by scope string ("owner/repo" or "org").
        var scopeToRunners: [String: [RunnerModel]] = [:]
        for runner in runners {
            guard let urlStr = runner.gitHubUrl,
                  let scope = scopeFrom(gitHubUrl: urlStr)
            else { continue }
            scopeToRunners[scope, default: []].append(runner)
        }

        // Fetch API data per scope and build a lookup: agentId → APIRunner.
        var apiByID: [Int: APIRunner] = [:]
        var apiByName: [String: APIRunner] = [:]

        for scope in scopeToRunners.keys {
            let endpoint: String
            if scope.contains("/") {
                endpoint = "repos/\(scope)/actions/runners?per_page=100"
            } else {
                endpoint = "orgs/\(scope)/actions/runners?per_page=100"
            }
            guard let data = ghAPI(endpoint),
                  let page = try? JSONDecoder().decode(APIRunnersPage.self, from: data)
            else {
                log("RunnerStatusEnricher › API call failed for scope: \(scope)")
                continue
            }
            for apiRunner in page.runners {
                apiByID[apiRunner.id] = apiRunner
                apiByName[apiRunner.name] = apiRunner
            }
            log("RunnerStatusEnricher › \(page.runners.count) runner(s) from GitHub for \(scope)")
        }

        // Apply enrichment and log divergence.
        return runners.map { runner in
            var enriched = runner
            let apiRunner: APIRunner?
            if let aid = runner.agentId {
                apiRunner = apiByID[aid]
            } else {
                apiRunner = apiByName[runner.runnerName]
            }
            guard let api = apiRunner else { return enriched }
            enriched.githubStatus = api.status
            enriched.isBusy = api.busy
            // Log divergence: local launchctl vs GitHub API disagreement.
            if runner.isRunning && api.status == "offline" {
                log("RunnerStatusEnricher › DIVERGENCE \(runner.runnerName): " +
                    "launchctl=running but GitHub=offline")
            } else if !runner.isRunning && api.status == "online" {
                log("RunnerStatusEnricher › DIVERGENCE \(runner.runnerName): " +
                    "launchctl=idle but GitHub=online")
            }
            return enriched
        }
    }

    // MARK: - Helpers

    /// Converts a `gitHubUrl` (e.g. `https://github.com/owner/repo` or
    /// `https://github.com/myorg`) into a scope string (`"owner/repo"` or
    /// `"myorg"`) suitable for the GitHub Actions runners API.
    private func scopeFrom(gitHubUrl: String) -> String? {
        guard let url = URL(string: gitHubUrl) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch parts.count {
        case 2:  return "\(parts[0])/\(parts[1])"
        case 1:  return parts[0]
        default: return nil
        }
    }
}
