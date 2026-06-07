// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation

// MARK: - LocalRunnerStore

/// Owns the list of locally-installed GitHub Actions runner agents.
/// Hydrates from `installPath/.runner` JSON, marks live services via launchctl,
/// then enriches with GitHub API data (status, busy, labels, group).
/// A single refresh cycle runs at a time; `isScanning` reflects in-flight state
/// to views and prevents concurrent refreshes.
@MainActor
final class LocalRunnerStore: ObservableObject {
    // MARK: - Shared singleton
    /// The app-wide singleton. Always accessed on the main actor.
    static let shared = LocalRunnerStore()

    // MARK: - Published state
    /// The current list of locally-installed runners, sorted by name.
    @Published private(set) var runners: [RunnerModel] = []
    /// `true` while a refresh cycle is in flight; prevents concurrent refreshes.
    @Published private(set) var isScanning: Bool = false

    // MARK: - Index persistence
    /// The UserDefaults key used to persist the local runner name → install path index.
    private static let indexKey = "localRunnerIndex"
    /// Maps runnerName → installPath, persisted to UserDefaults.
    private var runnerIndex: [String: String] = [:]

    // MARK: - Init
    /// Initialises the store and loads the persisted runner index from UserDefaults.
    /// NOTE: init() only populates runnerIndex (the name→path map).
    /// runners stays [] until refresh() is called explicitly.
    /// Callers MUST call refresh() after init to populate the runners array.
    private init() {
        loadIndex()
        log("LocalRunnerStore › init — runnerIndex.count=\(runnerIndex.count), runners=[] (call refresh() to hydrate)")
    }

    // MARK: - Index helpers

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    func register(name: String, installPath: String) {
        log("LocalRunnerStore › register — '\(name)' at \(installPath) (was: \(String(describing: runnerIndex[name])))")
        runnerIndex[name] = installPath
        persistIndex()
    }

    // MARK: - Convenience API (called by views)

    /// Returns `true` if `runnerName` has an entry in the persisted index.
    func isTracked(runnerName: String) -> Bool {
        let tracked = runnerIndex[runnerName] != nil
#if DEBUG
        log("LocalRunnerStore › isTracked '\(runnerName)' → \(tracked)")
#endif
        return tracked
    }

    /// Registers a new runner by name and install path.
    func add(runnerName: String, installPath: String) {
        log("LocalRunnerStore › add — '\(runnerName)' at \(installPath)")
        register(name: runnerName, installPath: installPath)
    }

    /// Immediately reflects a start/stop action in the UI before the next refresh cycle.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        log("LocalRunnerStore › optimisticallySetRunning '\(runnerName)' isRunning=\(isRunning)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ optimisticallySetRunning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(isRunning: isRunning)
    }

    /// Sets or clears the lifecycle warning badge for a runner.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        log("LocalRunnerStore › setLifecycleWarning '\(runnerName)' warning=\(String(describing: warning))")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ setLifecycleWarning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(lifecycleWarning: warning)
    }

    /// Immediately removes `runnerName` from the index and display list without waiting for a refresh.
    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)'")
        unregister(name: runnerName)
        let beforeCount = runners.count
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)' — runners \(beforeCount)→\(runners.count)")
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
    }

    /// Removes `name` from the persisted index.
    func unregister(name: String) {
        log("LocalRunnerStore › unregister '\(name)'")
        runnerIndex.removeValue(forKey: name)
        persistIndex()
    }

    /// Hydrates `runnerIndex` from `UserDefaults` at init time.
    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore › loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex.keys.sorted())")
    }

    /// Writes the current `runnerIndex` to `UserDefaults`.
    private func persistIndex() {
        UserDefaults.standard.set(runnerIndex, forKey: Self.indexKey)
        log("LocalRunnerStore › persistIndex — \(runnerIndex.count) entry(ies) written")
    }

    // MARK: - Metrics write-back

    /// Applies a CPU/memory snapshot to the matching `RunnerModel` in place.
    func applyMetrics(_ metrics: RunnerMetrics?, forAgentId agentId: Int?, name: String) {
#if DEBUG
        log("LocalRunnerStore › applyMetrics — agentId=\(String(describing: agentId)) name=\(name) metrics=\(String(describing: metrics))")
#endif
        guard let idx = runners.firstIndex(where: { runner in
            if let aid = agentId, let rid = runner.agentId { return aid == rid }
            return runner.runnerName == name
        }) else {
            log("LocalRunnerStore › ⚠️ applyMetrics — no matching runner for agentId=\(String(describing: agentId)) name=\(name) in runners.count=\(runners.count)")
            return
        }
        runners[idx] = runners[idx].copying(metrics: metrics)
    }

    // MARK: - Refresh

    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    ///
    /// IMPORTANT: This is the ONLY way runners gets populated.
    /// init() only loads runnerIndex (name→path). runners stays [] until refresh() runs.
    /// Must be called:
    ///   1. At app startup (AppDelegate+PanelSetup, BEFORE RunnerStore.start())
    ///   2. On-demand from views that need a fresh scan (e.g. SettingsView lifecycle actions)
    ///   3. From any view that needs a fresh scan (SettingsView, lifecycle actions)
    func refresh() {
        log("LocalRunnerStore › refresh() called — isScanning=\(isScanning) runnerIndex.count=\(runnerIndex.count) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore › refresh() — already scanning, skipping (isScanning=true)")
            return
        }
        isScanning = true
        let index = runnerIndex
        log("LocalRunnerStore › refresh() — starting Task with index=\(index.keys.sorted())")
        Task { [weak self] in
            guard let self else { return }

            // 1. Hydrate from installPath/.runner JSON
            var hydrated: [RunnerModel] = index.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
            log("LocalRunnerStore › refresh() hydrated \(hydrated.count) runner(s) from disk (index had \(index.count) entries)")
            if hydrated.count != index.count {
                let hydratedNames = Set(hydrated.map { $0.runnerName })
                let missing = index.keys.filter { !hydratedNames.contains($0) }
                log("LocalRunnerStore › ⚠️ refresh() — \(index.count - hydrated.count) runner(s) failed to hydrate (missing .runner JSON): \(missing)")
            }

            // 2. Mark live services via launchctl.
            let liveLabels = await self.scanLiveServices()
            log("LocalRunnerStore › refresh() — launchctl liveLabels.count=\(liveLabels.count): \(liveLabels)")
            let isLive: (RunnerModel) -> Bool = { runner in
                liveLabels.contains { $0.contains(runner.runnerName) }
            }
            hydrated = hydrated.map { runner in
                let live = isLive(runner)
#if DEBUG
                log("LocalRunnerStore › refresh() — '\(runner.runnerName)' isRunning=\(live)")
#endif
                return runner.copying(isRunning: live)
            }

            // 3. Enrich via GitHub API (concurrent scope fetches)
            log("LocalRunnerStore › refresh() — starting GitHub enrichment for \(hydrated.count) runner(s)")
            let enriched = await RunnerStatusEnricher.shared.enrich(runners: hydrated)
            log("LocalRunnerStore › refresh() — GitHub enrichment complete, \(enriched.count) runner(s) enriched")

            self.applyRefreshResults(enriched)
        }
    }

    /// Applies enriched runner data back on the main actor and clears the scanning flag.
    @MainActor
    private func applyRefreshResults(_ enriched: [RunnerModel]) {
        log("LocalRunnerStore › applyRefreshResults — enriched.count=\(enriched.count), preserving metrics from current runners.count=\(runners.count)")
        var metricsByAgentId: [Int: RunnerMetrics] = [:]
        var metricsByName: [String: RunnerMetrics] = [:]
        for runner in runners {
            guard runner.isBusy, let m = runner.metrics else { continue }
            if let aid = runner.agentId { metricsByAgentId[aid] = m }
            metricsByName[runner.runnerName] = m
        }
#if DEBUG
        log("LocalRunnerStore › applyRefreshResults — preserved metrics: byAgentId.count=\(metricsByAgentId.count) byName.count=\(metricsByName.count)")
#endif
        let preserved: [RunnerModel] = enriched.map { runner in
            if let aid = runner.agentId, let m = metricsByAgentId[aid] {
#if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via agentId=\(aid)")
#endif
                return runner.copying(metrics: m)
            }
            if let m = metricsByName[runner.runnerName] {
#if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via name")
#endif
                return runner.copying(metrics: m)
            }
            return runner
        }
        runners = preserved.sorted { $0.runnerName < $1.runnerName }
        isScanning = false
        log("LocalRunnerStore › applyRefreshResults — DONE. runners.count=\(runners.count) isScanning=false")
    }

    // MARK: - launchctl scan

    /// Path to the `launchctl` binary used to enumerate live runner services.
    nonisolated private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl") // NOSONAR

    /// Runs `launchctl list` and returns lines containing `actions.runner`.
    private nonisolated func scanLiveServices() async -> [String] {
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

// MARK: - .runner JSON parser

/// Reads `installPath/.runner` JSON and builds a RunnerModel.
private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    log("LocalRunnerStore › runnerModelFromIndex — parsing '\(name)' at \(installPath)")
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("LocalRunnerStore › ⚠️ runnerModelFromIndex — no .runner file at \(installPath), skipping '\(name)'")
        return nil
    }

    // Strip UTF-8 BOM (0xEF 0xBB 0xBF) — runner agent writes BOM-prefixed JSON.
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.prefix(3).elementsEqual(bom) {
        data = data.dropFirst(3)
        log("LocalRunnerStore › runnerModelFromIndex — stripped UTF-8 BOM from '\(name)'")
    }
    struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let agentId: Int?
        let workFolder: String?
        let platform: String?
        let platformArchitecture: String?
        let agentVersion: String?
        let ephemeral: Bool?
        enum CodingKeys: String, CodingKey {
            case gitHubUrl            = "gitHubUrl"
            case agentId              = "AgentId"
            case workFolder           = "WorkFolder"
            case platform             = "Platform"
            case platformArchitecture = "PlatformArchitecture"
            case agentVersion         = "AgentVersion"
            case ephemeral            = "Ephemeral"
        }
    }
    let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
    if json == nil {
        log("LocalRunnerStore › ⚠️ runnerModelFromIndex — JSON decode failed for '\(name)' at \(installPath). File may be malformed.")
    } else {
        log("LocalRunnerStore › runnerModelFromIndex — '\(name)' agentId=\(String(describing: json?.agentId)) gitHubUrl=\(String(describing: json?.gitHubUrl))")
    }
    return RunnerModel(
        runnerName: name,
        gitHubUrl: json?.gitHubUrl,
        agentId: json?.agentId,
        workFolder: json?.workFolder,
        installPath: installPath,
        isRunning: false,
        platform: json?.platform,
        platformArchitecture: json?.platformArchitecture,
        agentVersion: json?.agentVersion,
        isEphemeral: json?.ephemeral ?? false
    )
}
