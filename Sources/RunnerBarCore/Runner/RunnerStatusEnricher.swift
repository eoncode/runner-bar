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
        print("[Enricher] ════════════════════════════════════════════════")
        print("[Enricher] enrich() called with \(runners.count) runner(s)")
        for (i, r) in runners.enumerated() {
            print("[Enricher]   [\(i)] name='\(r.runnerName)' gitHubUrl=\(r.gitHubUrl ?? "NIL") agentId=\(r.agentId.map(String.init) ?? "nil") platform=\(r.platform ?? "nil") arch=\(r.platformArchitecture ?? "nil") labels=\(r.labels)")
        }

        // Step 1: collect unique scope URLs and the runners belonging to each.
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard let url = runner.gitHubUrl else {
                print("[Enricher] SKIP '\(runner.runnerName)' — gitHubUrl is nil, platform/arch cannot be enriched")
                continue
            }
            print("[Enricher] '\(runner.runnerName)' → scope URL='\(url)'")
            scopeToRunnerIndices[url, default: []].append(idx)
        }
        print("[Enricher] Unique scope URLs: \(scopeToRunnerIndices.keys.sorted())")

        // Step 2: fetch the full runner list for each scope once.
        // Key: runnerName, Value: raw API dictionary.
        var nameToAPI: [String: [String: Any]] = [:]
        for scopeURL in scopeToRunnerIndices.keys.sorted() {
            print("[Enricher] ── fetchRunnersForScope('\(scopeURL)')")
            let fetched = fetchRunnersForScope(scopeURL)
            print("[Enricher]    scope='\(scopeURL)' → \(fetched.count) API runner(s) returned")
            for apiRunner in fetched {
                if let name = apiRunner["name"] as? String {
                    let id = apiRunner["id"] as? Int ?? -1
                    let status = apiRunner["status"] as? String ?? "?"
                    let busy = apiRunner["busy"] as? Bool ?? false
                    let labels = (apiRunner["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    print("[Enricher]    API runner: name='\(name)' id=\(id) status=\(status) busy=\(busy) labels=\(labels)")
                    nameToAPI[name] = apiRunner
                } else {
                    print("[Enricher]    ⚠️ API runner has no 'name' field: \(apiRunner)")
                }
            }
        }
        print("[Enricher] nameToAPI keys after all scope fetches: \(nameToAPI.keys.sorted())")

        // Step 3: apply enrichment in a second pass.
        var result = runners
        for idx in result.indices {
            let name = result[idx].runnerName
            // Try exact match first.
            if let api = nameToAPI[name] {
                print("[Enricher] MATCH (exact) '\(name)' → applying enrichment")
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // Try case-insensitive match.
            let nameLower = name.lowercased()
            if let key = nameToAPI.keys.first(where: { $0.lowercased() == nameLower }),
               let api = nameToAPI[key] {
                print("[Enricher] MATCH (case-insensitive) '\(name)' → '\(key)' — applying enrichment")
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // Try trimmed whitespace match.
            let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
            if let key = nameToAPI.keys.first(where: { $0.trimmingCharacters(in: .whitespaces) == nameTrimmed }),
               let api = nameToAPI[key] {
                print("[Enricher] MATCH (trimmed) '\(name)' → '\(key)' — applying enrichment")
                result[idx] = applyEnrichment(to: result[idx], from: api)
                continue
            }
            // No match at all.
            print("[Enricher] NO MATCH for '\(name)'")
            print("[Enricher]   looked for exact: '\(name)'")
            print("[Enricher]   looked for lowercased: '\(nameLower)'")
            print("[Enricher]   available API names: \(nameToAPI.keys.sorted())")
            print("[Enricher]   gitHubUrl for this runner: \(result[idx].gitHubUrl ?? "NIL")")
            print("[Enricher]   agentId for this runner: \(result[idx].agentId.map(String.init) ?? "nil")")
        }
        print("[Enricher] ── enrich() result:")
        for r in result {
            print("[Enricher]   '\(r.runnerName)' platform=\(r.platform ?? "nil") arch=\(r.platformArchitecture ?? "nil") status=\(r.githubStatus ?? "nil") busy=\(r.isBusy) labels=\(r.labels)")
        }
        print("[Enricher] ════════════════════════════════════════════════")
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
        guard !ghIsRateLimited else {
            print("[Enricher] fetchRunnersForScope('\(scopeURL)') — RATE LIMITED, skipping")
            return []
        }

        let stripped = scopeURL.replacingOccurrences(of: "https://github.com/", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        print("[Enricher] fetchRunnersForScope — scopeURL='\(scopeURL)' stripped='\(stripped)' parts=\(parts)")
        guard !parts.isEmpty else {
            print("[Enricher] fetchRunnersForScope — parts is EMPTY, cannot build endpoint")
            return []
        }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
        let baseEndpoint: String
        if parts.count >= 2 {
            baseEndpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
            print("[Enricher] fetchRunnersForScope — REPO scope → \(baseEndpoint)")
        } else {
            baseEndpoint = "orgs/\(parts[0])/actions/runners"
            print("[Enricher] fetchRunnersForScope — ORG scope → \(baseEndpoint)")
        }

        var allRunners: [[String: Any]] = []
        var page = 1
        let perPage = 100

        repeat {
            guard !ghIsRateLimited else {
                print("[Enricher] fetchRunnersForScope — RATE LIMITED mid-pagination, stopping")
                break
            }
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"
            print("[Enricher] fetchRunnersForScope — requesting page \(page): \(endpoint)")

            guard let data = ghAPI(endpoint) else {
                print("[Enricher] fetchRunnersForScope — ghAPI returned nil for '\(endpoint)' (likely 403/404 or network error)")
                break
            }
            print("[Enricher] fetchRunnersForScope — got \(data.count) bytes from API for '\(endpoint)'")

            // Log raw JSON string for inspection (truncated to 500 chars)
            if let raw = String(data: data, encoding: .utf8) {
                let preview = raw.count > 500 ? String(raw.prefix(500)) + "…" : raw
                print("[Enricher] fetchRunnersForScope — raw JSON preview: \(preview)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Enricher] fetchRunnersForScope — JSONSerialization failed for '\(endpoint)'")
                break
            }
            print("[Enricher] fetchRunnersForScope — JSON top-level keys: \(json.keys.sorted())")

            guard let pageRunners = json["runners"] as? [[String: Any]] else {
                print("[Enricher] fetchRunnersForScope — 'runners' key missing or wrong type. Full JSON keys: \(json.keys.sorted())")
                // Log the total_count if present for debugging
                if let total = json["total_count"] { print("[Enricher] fetchRunnersForScope — total_count=\(total)") }
                break
            }

            print("[Enricher] fetchRunnersForScope — page \(page) returned \(pageRunners.count) runner(s)")
            for r in pageRunners {
                let n = r["name"] as? String ?? "<no name>"
                let id = r["id"] as? Int ?? -1
                print("[Enricher] fetchRunnersForScope   page \(page) runner: name='\(n)' id=\(id)")
            }
            allRunners.append(contentsOf: pageRunners)

            guard pageRunners.count == perPage else { break }
            page += 1
        } while true

        print("[Enricher] fetchRunnersForScope('\(scopeURL)') — total collected: \(allRunners.count) runner(s) across \(page) page(s)")
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

        print("[Enricher] applyEnrichment '\(runner.runnerName)':")
        print("[Enricher]   labelNamesFromAPI=\(labelNames)")
        print("[Enricher]   effectiveLabels=\(effectiveLabels) (source=\(labelNames.isEmpty ? "disk" : "API"))")
        print("[Enricher]   labelPlatform=\(labelPlatform ?? "nil") labelArch=\(labelArch ?? "nil")")
        print("[Enricher]   runner.platform(disk)=\(runner.platform ?? "nil") runner.arch(disk)=\(runner.platformArchitecture ?? "nil")")
        print("[Enricher]   → resolved platform=\(platform ?? "nil") arch=\(platformArchitecture ?? "nil")")

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
