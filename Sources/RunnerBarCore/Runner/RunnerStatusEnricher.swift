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
// through ghAPI so the gh-CLI fallback is available.
//
// NOTE: ghAPI returns Data?. fetchRunnersForScope decodes it via JSONSerialization
// rather than casting directly — a direct `as? [String: Any]` cast from Data? always
// fails at runtime because Data and Dictionary are unrelated types.
//
// NOTE: fetchRunnersForScope intentionally does NOT check ghIsRateLimited before
// calling ghAPI. The transport layer (GitHubURLSessionTransport) is the single
// source of truth for rate-limit state. A permission 403 on an org-scope endpoint
// must NOT prevent a subsequent repo-scope fetch from running — the two scopes use
// independent API paths and may have different token permissions.
//
// All methods are synchronous and blocking — always call from a background thread.
/// A value type representing RunnerStatusEnricher.
public struct RunnerStatusEnricher: Sendable {
    // MARK: - Shared singleton

    /// The shared `RunnerStatusEnricher` instance used throughout the app.
    public static let shared = RunnerStatusEnricher()

    /// Public memberwise initialiser.
    public init() {}

    /// Performs the enrich operation.
    public func enrich(runners: [RunnerModel]) -> [RunnerModel] {
        // Step 1: collect unique scope URLs and the runners belonging to each.
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard let url = runner.gitHubUrl else {
                log("[Enricher] SKIP '\(runner.runnerName)' — gitHubUrl is nil, platform/arch cannot be enriched")
                continue
            }
            scopeToRunnerIndices[url, default: []].append(idx)
        }

        // Step 2: fetch the full runner list for each scope once.
        // Key: runnerName, Value: raw API dictionary.
        var nameToAPI: [String: [String: Any]] = [:]
        for scopeURL in scopeToRunnerIndices.keys.sorted() {
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
            let name = result[idx].runnerName
            // Try exact match first.
            if let api = nameToAPI[name] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // Try case-insensitive match.
            let nameLower = name.lowercased()
            if let key = nameToAPI.keys.first(where: { $0.lowercased() == nameLower }),
               let api = nameToAPI[key] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // Try trimmed whitespace match.
            let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
            if let key = nameToAPI.keys.first(where: { $0.trimmingCharacters(in: .whitespaces) == nameTrimmed }),
               let api = nameToAPI[key] {
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // No match — warn so it's visible in logs without flooding every cycle.
            log("[Enricher] NO MATCH for '\(name)' — available API names: \(nameToAPI.keys.sorted()) gitHubUrl=\(result[idx].gitHubUrl ?? "NIL")")
        }
        return result
    }

    // MARK: - Private

    /// Fetches the **complete** runner list for a scope URL via ghAPI, paginating
    /// through all pages (per_page=100) until exhausted.
    /// Returns an empty array on failure.
    ///
    /// GitHub's default page size is 30. Without explicit pagination any org/repo
    /// with more than 30 runners would silently lose enrichment for runners beyond
    /// the first page. Using per_page=100 (the API maximum) minimises round-trips.
    ///
    /// NOTE: This method intentionally does NOT gate on ghIsRateLimited. A permission
    /// 403 on one scope (e.g. org) must not block a repo-scope fetch from running.
    /// The transport layer handles real rate-limits; duplicating the check here causes
    /// false skips when scopes are fetched sequentially and an org 403 fires first.
    private func fetchRunnersForScope(_ scopeURL: String) -> [[String: Any]] {
        let stripped = scopeURL.replacingOccurrences(of: "https://github.com/", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
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
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"
            guard let data = ghAPI(endpoint),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — ghAPI returned nil or JSON parse failed")
                break
            }
            let totalCount = json["total_count"] as? Int ?? -1
            guard let pageRunners = json["runners"] as? [[String: Any]] else {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — 'runners' key missing or wrong type. total_count=\(totalCount) top-level keys=\(json.keys.sorted())")
                break
            }
            log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) returned \(pageRunners.count) runners (total_count=\(totalCount))")
            for r in pageRunners {
                let name = r["name"] as? String ?? "<unnamed>"
                let id = r["id"] as? Int ?? -1
                let status = r["status"] as? String ?? "?"
                let busy = r["busy"] as? Bool ?? false
                let labels = (r["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                log("[Enricher] fetchRunnersForScope \(scopeURL) runner name=\(name) id=\(id) status=\(status) busy=\(busy) labels=\(labels)")
            }
            allRunners.append(contentsOf: pageRunners)
            guard pageRunners.count == perPage else { break }
            page += 1
        } while true

        log("[Enricher] fetchRunnersForScope \(scopeURL) total collected \(allRunners.count) runners")
        return allRunners
    }

    /// Applies fields from a raw GitHub API runner dictionary to a RunnerModel.
    private func applyEnrichment(to runner: RunnerModel, from api: [String: Any]) -> RunnerModel {
        let status = api["status"] as? String
        let busy = api["busy"] as? Bool ?? false
        let group = api["runner_group_name"] as? String
        let labelNames = (api["labels"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []

        // Derive platform and arch from API labels when the .runner JSON on disk
        // did not supply them (older runner agent versions omit these fields).
        // Labels like ["self-hosted", "macOS", "arm64"] are always present after
        // registration regardless of agent version.
        let effectiveLabels = labelNames.isEmpty ? runner.labels : labelNames
        let labelPlatform = effectiveLabels.first(where: { label in
            let l = label.lowercased()
            return l == "macos" || l == "linux" || l == "windows"
        })
        let labelArch = effectiveLabels.first(where: { label in
            let l = label.lowercased()
            return l == "arm64" || l == "x64" || l == "x86" || l == "aarch64"
        })
        // Prefer label-derived values (always correctly cased by GitHub)
        // over whatever .runner JSON provided (often nil or raw OS strings).
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
            githubStatus: status,
            isBusy: busy,
            lifecycleWarning: runner.lifecycleWarning,
            platform: platform,
            platformArchitecture: platformArchitecture,
            agentVersion: runner.agentVersion,
            isEphemeral: runner.isEphemeral,
            runnerGroup: group,
            metrics: runner.metrics
        )
    }
}
// swiftlint:enable function_parameter_count type_body_length
