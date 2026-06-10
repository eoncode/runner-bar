// LocalRunnerStore.swift
// RunnerBar
import Foundation

// MARK: - LocalRunnerStore

/// Swift 6 actor that owns the list of locally-installed GitHub Actions runner agents.
/// Hydrates from `installPath/.runner` JSON via `RunnerModelParser`,
/// marks live services via launchctl, then enriches with GitHub API data
/// (status, busy, labels, group).
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - After every refresh cycle, results are pushed to the injected `RunnerViewModel`
///   on the main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically.
/// - `isLocalScanning` is also pushed to `RunnerViewModel` so views can observe it
///   without holding a direct reference to the actor.
/// - Index persistence is delegated to `LocalRunnerIndex`.
/// - JSON parsing is delegated to `runnerModelFromIndex(name:installPath:)` in `RunnerModelParser`.
actor LocalRunnerStore {
    // MARK: - Shared instance
    /// The app-wide shared instance.
    /// Injected into views and stores via their `localRunnerStore` properties.
    /// Created lazily; `RunnerViewModel.shared` is passed at first access via `AppDelegate`.
    @MainActor static let shared = LocalRunnerStore(viewModel: RunnerViewModel.shared)

    // MARK: - Internal actor state
    /// The current list of locally-installed runners, sorted by name.
    private var runners: [RunnerModel] = []
    /// `true` while a refresh cycle is in flight; prevents concurrent refreshes.
    private var isScanning: Bool = false

    // MARK: - Injected dependencies
    /// The view model this actor pushes UI state into.
    private let viewModel: RunnerViewModel
    /// Persistence layer for the runner name → install path mapping.
    private let index = LocalRunnerIndex()

    // MARK: - Init
    /// Designated init for dependency injection.
    init(viewModel: RunnerViewModel) {
        self.viewModel = viewModel
        log("LocalRunnerStore › init — runnerIndex.count=\(index.runnerIndex.count), runners=[] (call refresh() to hydrate)")
    }

    // MARK: - Index helpers

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    func register(name: String, installPath: String) {
        index.register(name: name, installPath: installPath)
    }

    /// Removes `name` from the persisted index.
    func unregister(name: String) {
        index.unregister(name: name)
    }

    // MARK: - Convenience API (called by views via Task { await ... })

    /// Registers a new runner by name and install path.
    func add(runnerName: String, installPath: String) {
        log("LocalRunnerStore › add — '\(runnerName)' at \(installPath)")
        register(name: runnerName, installPath: installPath)
    }

    /// Immediately reflects a start/stop action before the next refresh cycle.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        log("LocalRunnerStore › optimisticallySetRunning '\(runnerName)' isRunning=\(isRunning)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ optimisticallySetRunning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(isRunning: isRunning)
        pushRunners()
    }

    /// Sets or clears the lifecycle warning badge for a runner.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        log("LocalRunnerStore › setLifecycleWarning '\(runnerName)' warning=\(String(describing: warning))")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ setLifecycleWarning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(lifecycleWarning: warning)
        pushRunners()
    }

    /// Immediately removes `runnerName` from the index and display list without waiting for a refresh.
    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)'")
        unregister(name: runnerName)
        let beforeCount = runners.count
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)' — runners \(beforeCount)→\(runners.count)")
        pushRunners()
    }

    /// Rolls back an `optimisticallyRemove` by re-registering the runner and restoring it.
    func optimisticallyRestore(_ runner: RunnerModel) {
        log("LocalRunnerStore › optimisticallyRestore '\(runner.runnerName)' installPath=\(String(describing: runner.installPath))")
        if let installPath = runner.installPath {
            register(name: runner.runnerName, installPath: installPath)
        } else {
            log("LocalRunnerStore › ⚠️ optimisticallyRestore — no installPath for '\(runner.runnerName)', index entry NOT restored")
        }
        if !runners.contains(where: { $0.runnerName == runner.runnerName }) {
            runners.append(runner)
            log("LocalRunnerStore › optimisticallyRestore — appended '\(runner.runnerName)', runners.count=\(runners.count)")
        } else {
            log("LocalRunnerStore › optimisticallyRestore — '\(runner.runnerName)' already present, skipped append")
        }
        pushRunners()
    }

    // MARK: - Metrics write-back

    /// Applies a CPU/memory snapshot to the matching `RunnerModel` in place.
    ///
    /// Match priority (fixes org-runner metrics #1209 / #1192):
    ///   1. runner.apiId   == runnerId (GitHub REST API id — org runners use this)
    ///   2. runner.agentId == runnerId (local .runner JSON AgentId — repo runners use this)
    ///   3. runner.runnerName == name  (name-only last resort)
    func applyMetrics(_ metrics: RunnerMetrics?, forRunnerId runnerId: Int?, name: String) {
#if DEBUG
        log("LocalRunnerStore › applyMetrics — called with runnerId=\(String(describing: runnerId)) name=\(name) metrics=\(String(describing: metrics))")
        log("LocalRunnerStore › applyMetrics — runners.count=\(runners.count) candidates=\(runners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
#endif

        guard let idx = runners.firstIndex(where: { runner in
            if let rid = runnerId, let aid = runner.apiId {
                if aid == rid {
                    log("LocalRunnerStore › applyMetrics — MATCH via apiId=\(aid) for '\(runner.runnerName)'")
                    return true
                }
            }
            if let rid = runnerId, let aid = runner.agentId {
                if aid == rid {
                    log("LocalRunnerStore › applyMetrics — MATCH via agentId=\(aid) for '\(runner.runnerName)'")
                    return true
                }
            }
            if runner.runnerName == name {
                log("LocalRunnerStore › applyMetrics — MATCH via name='\(name)' for '\(runner.runnerName)'")
                return true
            }
            return false
        }) else {
            log("LocalRunnerStore › ⚠️ applyMetrics — NO MATCH for runnerId=\(String(describing: runnerId)) name=\(name). runners=\(runners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
            return
        }
        log("LocalRunnerStore › applyMetrics — writing metrics=\(String(describing: metrics)) to '\(runners[idx].runnerName)'")
        runners[idx] = runners[idx].copying(metrics: metrics)
        pushRunners()
    }

    // MARK: - Refresh

    /// Fire-and-forget refresh. Spawns a Task and returns immediately.
    ///
    /// Use this from views and on-demand callers (e.g. SettingsView lifecycle actions)
    /// that do not need to wait for completion.
    ///
    /// At app startup, prefer `refreshAsync()` so that `RunnerStore.start()` is only
    /// called after `runners` is fully populated — ensuring cycle-1 `installPathMap`
    /// is never empty and metrics appear on first runner appearance.
    func refresh() {
        log("LocalRunnerStore › refresh() — fire-and-forget wrapper")
        Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// Awaitable refresh. Suspends until disk hydration + launchctl + GitHub enrichment
    /// completes, then returns.
    ///
    /// Use ONLY at app startup in `AppDelegate+PanelSetup` so that `RunnerStore.start()`
    /// is guaranteed to have a populated `runners` array before its first `fetch()` fires.
    func refreshAsync() async {
        await performRefresh()
    }

    /// Shared body for both `refresh()` and `refreshAsync()`.
    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    ///
    /// IMPORTANT: This is the ONLY way `runners` gets populated.
    /// `init()` only loads `runnerIndex` (name→path). `runners` stays `[]` until this runs.
    private func performRefresh() async {
        log("LocalRunnerStore › performRefresh() — isScanning=\(isScanning) runnerIndex.count=\(index.runnerIndex.count) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore › performRefresh() — already scanning, skipping (isScanning=true)")
            return
        }
        isScanning = true
        await MainActor.run { [viewModel] in viewModel.isLocalScanning = true }
        let currentIndex = index.runnerIndex
        log("LocalRunnerStore › performRefresh() — starting with index=\(currentIndex.keys.sorted())")

        // 1. Hydrate from installPath/.runner JSON
        var hydrated: [RunnerModel] = currentIndex.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
        log("LocalRunnerStore › performRefresh() hydrated \(hydrated.count) runner(s) from disk (index had \(currentIndex.count) entries)")
        if hydrated.count != currentIndex.count {
            let hydratedNames = Set(hydrated.map { $0.runnerName })
            let missing = currentIndex.keys.filter { !hydratedNames.contains($0) }
            log("LocalRunnerStore › ⚠️ performRefresh() — \(currentIndex.count - hydrated.count) runner(s) failed to hydrate (missing .runner JSON): \(missing)")
        }

        // 2. Mark live services via launchctl.
        let liveLabels = await scanLiveServices()
        log("LocalRunnerStore › performRefresh() — launchctl liveLabels.count=\(liveLabels.count): \(liveLabels)")
        hydrated = hydrated.map { runner in
            let live = liveLabels.contains { $0.contains(runner.runnerName) }
#if DEBUG
            log("LocalRunnerStore › performRefresh() — '\(runner.runnerName)' isRunning=\(live)")
#endif
            return runner.copying(isRunning: live)
        }

        // 3. Enrich via GitHub API (concurrent scope fetches)
        log("LocalRunnerStore › performRefresh() — starting GitHub enrichment for \(hydrated.count) runner(s)")
        let enriched = await RunnerStatusEnricher.shared.enrich(runners: hydrated)
        log("LocalRunnerStore › performRefresh() — GitHub enrichment complete, \(enriched.count) runner(s) enriched")
#if DEBUG
        log("LocalRunnerStore › performRefresh() — enriched apiIds=\(enriched.map { "\($0.runnerName)(apiId=\(String(describing: $0.apiId)) agentId=\(String(describing: $0.agentId)))" })")
#endif

        applyRefreshResults(enriched)
    }

    /// Applies enriched runner data, preserves in-flight metrics, pushes to viewModel.
    ///
    /// Metrics preservation priority (fixes org-runner metrics #1209 / #1192):
    ///   1. runner.apiId  match (org runners: GitHub REST API id ≠ local agentId)
    ///   2. runner.agentId match (repo runners)
    ///   3. runner.runnerName match (last resort)
    private func applyRefreshResults(_ enriched: [RunnerModel]) {
        log("LocalRunnerStore › applyRefreshResults — enriched.count=\(enriched.count), current runners.count=\(runners.count)")

        var metricsByApiId:   [Int: RunnerMetrics] = [:]
        var metricsByAgentId: [Int: RunnerMetrics] = [:]
        var metricsByName:    [String: RunnerMetrics] = [:]
        for runner in runners {
            guard runner.isBusy, let m = runner.metrics else { continue }
            if let id = runner.apiId   { metricsByApiId[id]   = m }
            if let id = runner.agentId { metricsByAgentId[id] = m }
            metricsByName[runner.runnerName] = m
        }
#if DEBUG
        log("LocalRunnerStore › applyRefreshResults — preserved metrics: byApiId=\(metricsByApiId.keys.sorted()) byAgentId=\(metricsByAgentId.keys.sorted()) byName=\(metricsByName.keys.sorted())")
#endif

        let preserved: [RunnerModel] = enriched.map { runner in
            if let id = runner.apiId, let m = metricsByApiId[id] {
#if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via apiId=\(id)")
#endif
                return runner.copying(metrics: m)
            }
            if let id = runner.agentId, let m = metricsByAgentId[id] {
#if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via agentId=\(id)")
#endif
                return runner.copying(metrics: m)
            }
            if let m = metricsByName[runner.runnerName] {
#if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via name")
#endif
                return runner.copying(metrics: m)
            }
#if DEBUG
            log("LocalRunnerStore › applyRefreshResults — no metrics to preserve for '\(runner.runnerName)'")
#endif
            return runner
        }
        runners = preserved.sorted { $0.runnerName < $1.runnerName }
        isScanning = false
        log("LocalRunnerStore › applyRefreshResults — DONE. runners.count=\(runners.count) isScanning=false")
        let snapshot = runners
        Task { await MainActor.run { [viewModel] in
            viewModel.localRunners = snapshot
            viewModel.isLocalScanning = false
        } }
    }

    // MARK: - Push helpers

    /// Pushes the current `runners` snapshot to `viewModel.localRunners` on the main actor.
    /// Called after every optimistic mutation so views update immediately.
    private func pushRunners() {
        let snapshot = runners
        Task { await MainActor.run { [viewModel] in viewModel.localRunners = snapshot } }
    }

    // MARK: - launchctl scan

    /// Path to the `launchctl` binary used to enumerate live runner services.
    private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl") // NOSONAR

    /// Runs `launchctl list` and returns lines containing `actions.runner`.
    private func scanLiveServices() async -> [String] {
        log("LocalRunnerStore › scanLiveServices — running launchctl list")
        let result = await ProcessRunner.runAsync(
            executableURL: Self.launchctlURL,
            arguments: ["list"],
            timeout: 5
        )
        guard let data = result.data,
              let output = String(data: data, encoding: .utf8) else {
            log("LocalRunnerStore › ⚠️ scanLiveServices — launchctl returned no data or non-UTF8 output")
            return []
        }
        let lines = output.components(separatedBy: "\n").filter { $0.contains("actions.runner") }
        log("LocalRunnerStore › scanLiveServices — found \(lines.count) live actions.runner service(s)")
        return lines
    }
}
