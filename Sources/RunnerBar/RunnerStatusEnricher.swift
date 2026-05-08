import Foundation

// MARK: - RunnerStatusEnricher

/// Phase 4: Enriches locally-discovered `RunnerModel` values with live status
/// from the GitHub API.
///
/// Uses the `gitHubUrl` already stored in each runner to call only the targeted
/// API endpoints — no brute-force org/repo iteration. One paginated API call
/// series per unique scope (owner/repo or org) in the runner list.
///
/// All methods are synchronous and blocking — always call from a background thread.
struct RunnerStatusEnricher {
    // MARK: - Shared singleton

    /// The shared `RunnerStatusEnricher` instance used throughout the app.
    static let shared = RunnerStatusEnricher()
    private init() {}

    // MARK: - Codable schema

    /// Decodable mirror of one runner entry from the GitHub Actions runners API.
    private struct APIRunner: Decodable {
        let id: Int
        let name: String
        let status: String
        let busy: Bool
    }

    private struct APIRunnersPage: Decodable {
        let runners: [APIRunner]
    }

    // MARK: - Public API

    /// Fetches live GitHub status for all runners whose `gitHubUrl` is known
    /// and returns a new array with `githubStatus` and `isBusy` populated.
    /// Runners without a `gitHubUrl` are returned unchanged — their
    /// `statusColor` continues to reflect the local launchctl-derived state.
    func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        guard !runners.isEmpty else { return runners }

        let apiLookup = buildAPILookup(for: runners)
        return runners.map { applyEnrichment(to: $0, lookup: apiLookup) }
    }

    // MARK: - Private helpers

    /// Fetches runner status from the GitHub API for each unique scope in `runners`
    /// using manual `?page=N` iteration so that scopes with more than 100 runners
    /// are fully captured.
    ///
    /// `gh api --paginate` emits concatenated JSON objects
    /// (`{"runners":[...]}\n{"runners":[...]}`) which `JSONDecoder` cannot parse
    /// as a single value. Manual iteration avoids this entirely.
    ///
    /// Returns a lookup keyed by `agentId` (primary) and `"scope/name"`
    /// (fallback, scope-qualified to prevent cross-scope collisions).
    private func buildAPILookup(
        for runners: [RunnerModel]
    ) -> (byID: [Int: APIRunner], byName: [String: APIRunner]) {
        var scopeToRunners: [String: [RunnerModel]] = [:]
        for runner in runners {
            guard let urlStr = runner.gitHubUrl,
                  let scope = scopeFrom(gitHubUrl: urlStr)
            else { continue }
            scopeToRunners[scope, default: []].append(runner)
        }

        var byID: [Int: APIRunner] = [:]
        var byName: [String: APIRunner] = [:]

        for scope in scopeToRunners.keys {
            let baseEndpoint = scope.contains("/")
                ? "repos/\(scope)/actions/runners"
                : "orgs/\(scope)/actions/runners"

            // Paginate manually: fetch ?page=1,2,… until an empty runners array.
            // This avoids the `gh --paginate` concatenated-object stream problem
            // where multiple {"runners":[...]} objects cannot be decoded as one value.
            var page = 1
            var totalFetched = 0
            while true {
                let endpoint = "\(baseEndpoint)?per_page=100&page=\(page)"
                guard let data = ghAPI(endpoint) else {
                    log("RunnerStatusEnricher › API call failed for scope: \(scope) page: \(page)")
                    break
                }
                guard let decoded = try? JSONDecoder().decode(APIRunnersPage.self, from: data) else {
                    log("RunnerStatusEnricher › decode failed for scope: \(scope) page: \(page)")
                    break
                }
                let pageRunners = decoded.runners
                for apiRunner in pageRunners {
                    byID[apiRunner.id] = apiRunner
                    // Key by "scope/name" to prevent silent overwrites when runners
                    // across different scopes share the same name.
                    byName["\(scope)/\(apiRunner.name)"] = apiRunner
                }
                totalFetched += pageRunners.count
                log("RunnerStatusEnricher › scope=\(scope) page=\(page) fetched=\(pageRunners.count)")
                // Stop when a page returns fewer than 100 results — no more pages.
                if pageRunners.count < 100 { break }
                page += 1
            }
            log("RunnerStatusEnricher › \(totalFetched) total runner(s) from GitHub for \(scope)")
        }
        return (byID, byName)
    }

    /// Applies GitHub API status to a single `RunnerModel`, logging divergence.
    private func applyEnrichment(
        to runner: RunnerModel,
        lookup: (byID: [Int: APIRunner], byName: [String: APIRunner])
    ) -> RunnerModel {
        var enriched = runner
        let apiRunner: APIRunner?
        if let aid = runner.agentId {
            apiRunner = lookup.byID[aid]
        } else if let urlStr = runner.gitHubUrl,
                  let scope = scopeFrom(gitHubUrl: urlStr) {
            // Fallback: look up by scope-qualified key to avoid cross-scope collision.
            apiRunner = lookup.byName["\(scope)/\(runner.runnerName)"]
        } else {
            apiRunner = nil
        }
        guard let api = apiRunner else { return enriched }
        enriched.githubStatus = api.status
        enriched.isBusy = api.busy
        if runner.isRunning && api.status == "offline" {
            log("RunnerStatusEnricher › DIVERGENCE \(runner.runnerName): " +
                "launchctl=running but GitHub=offline")
        } else if !runner.isRunning && api.status == "online" {
            log("RunnerStatusEnricher › DIVERGENCE \(runner.runnerName): " +
                "launchctl=idle but GitHub=online")
        }
        return enriched
    }

    // MARK: - Helpers

    /// Converts a `gitHubUrl` into a scope string (`"owner/repo"` or `"org"`)
    /// suitable for the GitHub Actions runners API.
    private func scopeFrom(gitHubUrl: String) -> String? {
        guard let url = URL(string: gitHubUrl) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch parts.count {
        case 2: return "\(parts[0])/\(parts[1])"
        case 1: return parts[0]
        default: return nil
        }
    }
}
