// RunnerPoller+FetchAndEnrich.swift
// RunnerBarCore

// swiftlint:disable:next missing_docs
extension RunnerPoller {

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners for the given scopes, resolves install paths, and enriches with metrics.
    ///
    /// `internal` — `fetch()` is the public entry point; this method is an implementation
    /// detail not intended for direct external calls.
    ///
    /// **Phase 0** is now handled by `deriveExtraOrgScopes(from:configuredScopes:)` in
    /// `RunnerPoller.swift`, called before `buildInstallPathMap` in `fetchInternal`. The
    /// pre-computed `extraOrgScopes` are passed in so `byFullKey` covers inferred org
    /// scopes as well as user-configured ones.
    ///
    /// **Phase 1** fans out concurrent scope fetches via `withTaskGroup`. Task completion order
    /// is non-deterministic; views sort runners for display independently.
    ///
    /// **Phase 2** enriches each busy runner with system metrics concurrently.
    ///
    /// **Install-path lookup priority** (matches the original `RunnerStore`):
    /// `byApiId ?? byAgentId ?? byFullKey ?? byName`
    /// `byFullKey` ("scope/name" composite) ranks above `byName` so runners sharing
    /// a name across different scopes resolve to the correct install path.
    ///
    /// - Parameters:
    ///   - scopes: The user-configured active scopes.
    ///   - extraOrgScopes: Inferred org scopes derived from local runner URLs (may be empty).
    ///   - localRunners: The current local-runner snapshot.
    ///   - installPathMap: Pre-built lookup maps from `buildInstallPathMap`, built with
    ///     `scopes + extraOrgScopes` so `byFullKey` covers all fetched scopes.
    func fetchAndEnrichRunners(
        scopes: [String],
        extraOrgScopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        let allScopes = scopes + extraOrgScopes
        log("RunnerPoller › fetchAndEnrichRunners ENTER — scopes=\(scopes) extraOrgScopes=\(extraOrgScopes)", category: .runner)

        // MARK: Phase 1 — Fetch raw runners for all scopes concurrently
        var indexed: [IndexedScopedRunner] = []
        await withTaskGroup(of: (String, [Runner]).self) { group in
            for scope in allScopes {
                group.addTask {
                    let fetched = await fetchRunners(for: scope, decoder: self.decoder)
                    return (scope, fetched)
                }
            }
            for await (scope, fetched) in group {
                indexed.append(contentsOf: fetched.map { IndexedScopedRunner(scope: scope, runner: $0) })
            }
        }

        // MARK: Phase 2 — Enrich each busy runner with system metrics concurrently
        // Lookup priority: byApiId ?? byAgentId ?? byFullKey ?? byName
        let busyIndices = indexed.indices.filter { indexed[$0].runner.busy }
        if !busyIndices.isEmpty {
            let metricsResults: [(Int, RunnerMetrics?)] = await withTaskGroup(
                of: (Int, RunnerMetrics?).self
            ) { group in
                for i in busyIndices {
                    let runner = indexed[i].runner
                    let scope = indexed[i].scope
                    let installPath = installPathMap.byApiId[runner.id]
                        ?? installPathMap.byAgentId[runner.id]
                        ?? installPathMap.byFullKey["\(scope)/\(runner.name)"]
                        ?? installPathMap.byName[runner.name]
                    guard let path = installPath else {
                        log("RunnerPoller › fetchAndEnrichRunners — no installPath for \(runner.name) id=\(runner.id) scope=\(scope)", category: .runner)
                        continue
                    }
                    group.addTask {
                        let metrics = await metricsForRunner(installPath: path)
                        return (i, metrics)
                    }
                }
                var results: [(Int, RunnerMetrics?)] = []
                for await pair in group { results.append(pair) }
                return results
            }
            for (i, metrics) in metricsResults {
                indexed[i].runner = indexed[i].runner.copying(metrics: metrics)
            }
        }

        let metricsUpdates = indexed.filter { $0.runner.busy && $0.runner.metrics != nil }
        if !metricsUpdates.isEmpty {
            for entry in metricsUpdates {
#if DEBUG
                // swiftlint:disable:next line_length
                log("RunnerPoller › fetchAndEnrichRunners — applyMetrics: \(entry.runner.name) id=\(entry.runner.id) busy=\(entry.runner.busy) metrics=\(String(describing: entry.runner.metrics))", category: .runner)
#endif
                await applyMetrics(entry.runner.metrics, entry.runner.id, entry.runner.name)
            }
        }

        let result = indexed.map(\.runner)
        log("RunnerPoller › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)", category: .runner)
        return result
    }
}
