// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation
import RunnerBarCore

// MARK: - LocalRunnerStore

// swiftlint:disable type_body_length missing_docs
/// Manages the list of locally-known self-hosted runners.
/// Persists a minimal index of runnerName → installPath in UserDefaults.
/// All runner state (isRunning, githubStatus, metrics, etc.) is pulled live on refresh().
@MainActor
final class LocalRunnerStore: ObservableObject {
    /// The shared constant.
    static let shared = LocalRunnerStore()

    /// UserDefaults key for the [runnerName: installPath] index.
    private static let indexKey = "LocalRunnerStore.index"

    /// Private initialiser — use `shared`.
    private init() {
        loadIndex()
    }

    /// The published runner list — rebuilt from the index on every refresh().
    @Published var runners: [RunnerModel] = []
    /// The isScanning property.
    @Published var isScanning: Bool = false

    /// Persisted index: runnerName → installPath.
    private var runnerIndex: [String: String] = [:]

    /// The enricher constant.
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Index management

    /// Adds a runner to the persisted index and triggers a refresh.
    /// No-op if a runner with the same name is already tracked.
    func add(runnerName: String, installPath: String) {
        guard runnerIndex[runnerName] == nil else {
            log("LocalRunnerStore > add — \(runnerName) already tracked, skipping")
            return
        }
        runnerIndex[runnerName] = installPath
        persistIndex()
        log("LocalRunnerStore > add — added \(runnerName) at \(installPath)")
        refresh()
    }

    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore > loadIndex — \(runnerIndex.count) entry(ies)")
    }

    private func persistIndex() {
        UserDefaults.standard.set(runnerIndex, forKey: Self.indexKey)
        log("LocalRunnerStore > persistIndex — saved \(runnerIndex.count) entry(ies)")
    }

    // MARK: - Refresh

    /// Hydrates RunnerModels from the persisted index, marks live state, enriches via API.
    func refresh() {
        log("LocalRunnerStore > refresh() called — isScanning=\(isScanning) index.count=\(runnerIndex.count)")
        guard !isScanning else {
            log("LocalRunnerStore > refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        let enricher = self.enricher
        let index = self.runnerIndex
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
            var enriched = hydrated
            if githubToken() != nil {
                log("LocalRunnerStore > refresh() background — token present, calling enricher")
                enriched = enricher.enrich(runners: hydrated)
                log("LocalRunnerStore > refresh() background — enricher returned \(enriched.count) runner(s): [\(runnerEnrichedSummary(enriched))]")
            } else {
                log("LocalRunnerStore > refresh() background — no token, skipping enricher")
            }

            // 4. Apply CPU/MEM metrics
            applyMetrics(&enriched)

            DispatchQueue.main.async { [weak self, enriched] in
                guard let self else { return }
                self.runners = enriched.sorted { $0.runnerName < $1.runnerName }
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done. runners.count=\(self.runners.count)")
            }
        }
    }

    // MARK: - Optimistic mutations

    /// Performs the optimisticallyRemove operation.
    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore > optimisticallyRemove — runnerName=\(runnerName)")
        runners.removeAll { $0.runnerName == runnerName }
        runnerIndex.removeValue(forKey: runnerName)
        persistIndex()
        log("LocalRunnerStore > optimisticallyRemove — done, runners.count=\(runners.count)")
    }

    /// Performs the optimisticallySetRunning operation.
    func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) {
        let names = runners.map { $0.runnerName }.joined(separator: ", ")
        log("LocalRunnerStore > optimisticallySetRunning runnerName=\(runnerName) isRunning=\(isRunning) — current runners=[\(names)]")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > optimisticallySetRunning — NOT FOUND for \(runnerName)")
            return
        }
        runners[idx].isRunning = isRunning
        runners[idx].lifecycleWarning = nil
        objectWillChange.send()
        log("LocalRunnerStore > optimisticallySetRunning — done")
    }

    /// Performs the setLifecycleWarning operation.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        let w = warning ?? "nil"
        log("LocalRunnerStore > setLifecycleWarning called: runnerName=\(runnerName) warning=\(w)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > setLifecycleWarning — NOT FOUND for \(runnerName)")
            return
        }
        runners[idx].lifecycleWarning = warning
        objectWillChange.send()
        let displayStatus = runners[idx].displayStatus
        log("LocalRunnerStore > setLifecycleWarning — done for \(runnerName), displayStatus is now: \(displayStatus)")
    }
}
// swiftlint:enable type_body_length missing_docs

// MARK: - Private helpers

/// Reads `installPath/.runner` JSON and builds a RunnerModel.
/// Returns nil if the file is missing — runner may have been uninstalled outside the app.
private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard let data = try? Data(contentsOf: jsonURL) else {
        log("LocalRunnerStore > runnerModelFromIndex — no .runner at \(installPath), skipping \(name)")
        return nil
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
            case gitHubUrl            = "GitHubUrl"
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
        workFolder: json?.workFolder ?? installPath,
        installPath: installPath,
        isRunning: false,
        platform: json?.platform,
        platformArchitecture: json?.platformArchitecture,
        agentVersion: json?.agentVersion,
        isEphemeral: json?.ephemeral ?? false
    )
}

/// Returns active launchd service labels containing "actions.runner" via `launchctl list`.
private func scanLiveServices() -> Set<String> {
    let result = ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
        arguments: ["list"],
        timeout: 5
    )
    guard !result.output.isEmpty else { return [] }
    var labels = Set<String>()
    for line in result.output.components(separatedBy: "\n") where line.contains("actions.runner") {
        let cols = line.components(separatedBy: "\t")
        guard cols.count >= 3 else { continue }
        let pid   = cols[0].trimmingCharacters(in: .whitespaces)
        let label = cols[2].trimmingCharacters(in: .whitespaces)
        if pid != "-", !label.isEmpty { labels.insert(label) }
    }
    return labels
}

/// Returns a compact enriched summary string.
private func runnerEnrichedSummary(_ runners: [RunnerModel]) -> String {
    runners.map { r in
        let st = r.githubStatus ?? "nil"
        let w  = r.lifecycleWarning ?? "none"
        return "\(r.runnerName)(isRunning=\(r.isRunning),status=\(st),warning=\(w))"
    }.joined(separator: ", ")
}

/// Mutates each runner in-place to attach CPU/MEM metrics for running runners.
private func applyMetrics(_ enriched: inout [RunnerModel]) {
    for idx in enriched.indices {
        guard enriched[idx].isRunning, let installPath = enriched[idx].installPath else { continue }
        enriched[idx].metrics = metricsForRunner(installPath: installPath)
        log("LocalRunnerStore > applyMetrics — \(enriched[idx].runnerName): \(String(describing: enriched[idx].metrics))")
    }
}
