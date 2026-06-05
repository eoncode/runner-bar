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
    private init() {
        loadIndex()
    }

    // MARK: - Index helpers

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    func register(name: String, installPath: String) {
        runnerIndex[name] = installPath
        persistIndex()
        log("LocalRunnerStore > register — '\(name)' at \(installPath)")
    }

    func isTracked(runnerName: String) -> Bool {
        runnerIndex[runnerName] != nil
    }

    func add(runnerName: String, installPath: String) {
        register(name: runnerName, installPath: installPath)
    }

    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx] = runners[idx].copying(isRunning: isRunning)
    }

    /// Sets or clears the `lifecycleWarning` string shown in the runner row.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx] = runners[idx].copying(lifecycleWarning: warning)
    }

    /// Immediately removes `runnerName` from the index and display list without waiting for a refresh.
    func optimisticallyRemove(_ runnerName: String) {
        unregister(name: runnerName)
        runners.removeAll { $0.runnerName == runnerName }
    }

    /// Re-adds a previously removed runner to the index and display list (undo support).
    func optimisticallyRestore(_ runner: RunnerModel) {
        if let installPath = runner.installPath {
            register(name: runner.runnerName, installPath: installPath)
        } else {
            log("LocalRunnerStore > optimisticallyRestore: no installPath for '\(runner.runnerName)' — index entry not restored")
        }
        if !runners.contains(where: { $0.runnerName == runner.runnerName }) {
            runners.append(runner)
        }
    }

    /// Removes `name` from the persisted index and writes through to `UserDefaults`.
    func unregister(name: String) {
        runnerIndex.removeValue(forKey: name)
        persistIndex()
        log("LocalRunnerStore > unregister — '\(name)'")
    }

    /// Hydrates `runnerIndex` from `UserDefaults` at init time.
    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore > loadIndex — \(runnerIndex.count) entry(ies)")
    }

    /// Writes the current `runnerIndex` to `UserDefaults`.
    private func persistIndex() {
        UserDefaults.standard.set(runnerIndex, forKey: Self.indexKey)
    }

    // MARK: - Refresh

    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    ///
    /// Runs background work in a plain `Task` so actor context, priority, and
    /// cancellation are inherited from the `@MainActor` caller. The continuation
    /// returns to `@MainActor` automatically via `applyRefreshResults`.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let index = runnerIndex
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // 1. Hydrate from installPath/.runner JSON
            var hydrated: [RunnerModel] = index.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
            log("LocalRunnerStore > refresh() background — hydrated \(hydrated.count) runner(s)")

            // 2. Mark live services via launchctl.
            let liveLabels = await self.scanLiveServices()
            let isLive: (RunnerModel) -> Bool = { runner in
                liveLabels.contains { $0.contains(runner.runnerName) }
            }
            hydrated = hydrated.map { runner in
                runner.copying(isRunning: isLive(runner))
            }

            // 3. Enrich via GitHub API (concurrent scope fetches)
            let enriched = await RunnerStatusEnricher.shared.enrich(runners: hydrated)

            await self.applyRefreshResults(enriched)
        }
    }

    /// Applies enriched runner data back on the main actor and clears the scanning flag.
    @MainActor
    private func applyRefreshResults(_ enriched: [RunnerModel]) {
        runners = enriched.sorted { $0.runnerName < $1.runnerName }
        isScanning = false
        log("LocalRunnerStore > refresh() main — done. runners.count=\(runners.count)")
    }

    // MARK: - launchctl scan

    /// Fixed path to the `launchctl` binary used to query live LaunchAgent services.
    nonisolated private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl") // NOSONAR — fixed OS path

    /// Runs `launchctl list` and returns lines containing `actions.runner`.
    ///
    /// Marked `async` so it can be awaited from the `Task` body in `refresh()`
    /// and to allow the blocking `ProcessRunner.run` call to suspend off the
    /// main actor.
    private nonisolated func scanLiveServices() async -> [String] {
        let result = ProcessRunner.run(
            executableURL: Self.launchctlURL,
            arguments: ["list"],
            timeout: 5
        )
        guard let data = result.data,
              let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n").filter { $0.contains("actions.runner") }
    }
}

// MARK: - .runner JSON parser

private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("LocalRunnerStore > runnerModelFromIndex — no .runner at \(installPath), skipping \(name)")
        return nil
    }
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.prefix(3).elementsEqual(bom) {
        data = data.dropFirst(3)
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
            case gitHubUrl            = "gitHubUrl" // must match runner agent JSON exactly — agent writes camelCase
            case agentId              = "AgentId"
            case workFolder           = "WorkFolder"
            case platform             = "Platform"
            case platformArchitecture = "PlatformArchitecture"
            case agentVersion         = "AgentVersion"
            case ephemeral            = "Ephemeral"
        }
    }
    let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
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
