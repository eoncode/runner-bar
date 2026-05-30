// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation

// MARK: - LocalRunnerStore
//
// Owns the list of locally-installed GitHub Actions runner agents.
// Hydrates from installPath/.runner JSON, marks live services via launchctl,
// then enriches with GitHub API data (status, busy, labels, group).
//
// Polling:
//   • refresh() is called by RunnerViewModel on every displayTick (≈1 Hz).
//   • The heavy work (disk I/O + API calls) runs on a background queue.
//   • isScanning prevents concurrent refreshes.

/// Owns the list of locally-installed GitHub Actions runner agents.
/// Hydrates from `installPath/.runner` JSON, marks live services via launchctl,
/// then enriches with GitHub API data (status, busy, labels, group).
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

    // MARK: - Convenience API (called by views)

    /// Returns `true` if `runnerName` has an entry in the persisted index.
    func isTracked(runnerName: String) -> Bool {
        runnerIndex[runnerName] != nil
    }

    /// Registers a new runner by name and install path.
    func add(runnerName: String, installPath: String) {
        register(name: runnerName, installPath: installPath)
    }

    /// Immediately reflects a start/stop action in the UI before the next refresh cycle.
    /// Already runs on the main actor via @MainActor class isolation.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx].isRunning = isRunning
    }

    /// Sets or clears the lifecycle warning badge for a runner (e.g. "Failed to connect").
    /// Already runs on the main actor via @MainActor class isolation.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else { return }
        runners[idx].lifecycleWarning = warning
    }

    /// Removes a runner from both the index and the published list immediately.
    /// Already runs on the main actor via @MainActor class isolation.
    func optimisticallyRemove(_ runnerName: String) {
        unregister(name: runnerName)
        runners.removeAll { $0.runnerName == runnerName }
    }

    /// Removes the index entry for `name` and persists the updated index.
    func unregister(name: String) {
        runnerIndex.removeValue(forKey: name)
        persistIndex()
        log("LocalRunnerStore > unregister — '\(name)'")
    }

    /// Loads the runner index from UserDefaults into `runnerIndex`.
    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore > loadIndex — \(runnerIndex.count) entry(ies)")
    }

    /// Writes the current `runnerIndex` to UserDefaults.
    private func persistIndex() {
        UserDefaults.standard.set(runnerIndex, forKey: Self.indexKey)
    }

    // MARK: - Refresh

    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    /// Must be called on the main actor; heavy work is dispatched to a background queue internally.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let index = runnerIndex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. Hydrate from installPath/.runner JSON
            var hydrated: [RunnerModel] = index.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
            log("LocalRunnerStore > refresh() background — hydrated \(hydrated.count) runner(s)")

            // 2. Mark live services via launchctl
            let liveLabels = scanLiveServices()
            for idx in hydrated.indices {
                hydrated[idx].isRunning = liveLabels.contains { $0.contains(hydrated[idx].runnerName) }
            }

            // 3. Enrich via GitHub API
            let enriched = RunnerStatusEnricher.shared.enrich(runners: hydrated)

            DispatchQueue.main.async {
                self.runners = enriched.sorted { $0.runnerName < $1.runnerName }
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done. runners.count=\(self.runners.count)")
            }
        }
    }

    // MARK: - launchctl scan

    /// Runs `launchctl list` and returns lines whose label contains `actions.runner`.
    private nonisolated func scanLiveServices() -> [String] {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["list"],
            timeout: 5
        )
        guard let data = result.data,
              let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n").filter { $0.contains("actions.runner") }
    }
}

// MARK: - .runner JSON parser

/// Reads `installPath/.runner` JSON and builds a RunnerModel.
/// Returns nil if the file is missing — runner may have been uninstalled outside the app.
///
/// The GitHub Actions runner agent writes .runner files with a UTF-8 BOM (0xEF 0xBB 0xBF).
/// Swift's JSONDecoder does not strip BOMs and silently returns nil for the entire decode.
/// We strip the BOM from the raw Data before passing it to the decoder.
///
/// The agent also writes "gitHubUrl" in camelCase; the CodingKey must match exactly
/// since JSONDecoder is case-sensitive.
private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("LocalRunnerStore > runnerModelFromIndex — no .runner at \(installPath), skipping \(name)")
        return nil
    }

    // Strip UTF-8 BOM (0xEF 0xBB 0xBF) — runner agent writes BOM-prefixed JSON on all platforms.
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
            case gitHubUrl            = "gitHubUrl"           // camelCase — matches runner agent output
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
