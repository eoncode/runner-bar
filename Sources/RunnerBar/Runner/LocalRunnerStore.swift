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

    /// Returns true if the given runner name is already in the persisted index.
    func isTracked(runnerName: String) -> Bool {
        runnerIndex[runnerName] != nil
    }

    private func loadIndex() {
        runnerIndex = UserDefaults.standard
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerStore > loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex)")
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
            for r in hydrated {
                log("LocalRunnerStore > hydrated: name='\(r.runnerName)' gitHubUrl=\(r.gitHubUrl ?? "NIL") agentId=\(r.agentId.map(String.init) ?? "nil") platform=\(r.platform ?? "nil") arch=\(r.platformArchitecture ?? "nil") installPath=\(r.installPath ?? "nil")")
            }

            // 2. Mark live services via launchctl
            let liveLabels = scanLiveServices()
            log("LocalRunnerStore > liveLabels from launchctl: \(liveLabels.sorted())")
            for idx in hydrated.indices {
                let wasRunning = hydrated[idx].isRunning
                hydrated[idx].isRunning = liveLabels.contains { $0.contains(hydrated[idx].runnerName) }
                log("LocalRunnerStore > isRunning '\(hydrated[idx].runnerName)': \(wasRunning) → \(hydrated[idx].isRunning)")
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
                for r in self.runners {
                    log("LocalRunnerStore > final runner: name='\(r.runnerName)' platform=\(r.platform ?? "nil") arch=\(r.platformArchitecture ?? "nil") status=\(r.githubStatus ?? "nil") busy=\(r.isBusy) labels=\(r.labels)")
                }
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
///
/// The GitHub Actions runner agent writes .runner files with a UTF-8 BOM (0xEF 0xBB 0xBF).
/// Swift's JSONDecoder does not strip BOMs and silently returns nil for the entire decode.
/// We strip the BOM from the raw Data before passing it to the decoder.
///
/// The agent also writes "gitHubUrl" in camelCase; the CodingKey must match exactly
/// since JSONDecoder is case-sensitive.
private func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    log("runnerModelFromIndex — reading '\(jsonURL.path)' for runner '\(name)'")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("runnerModelFromIndex — ⚠️ no .runner file at '\(jsonURL.path)', skipping '\(name)'")
        return nil
    }
    log("runnerModelFromIndex — read \(data.count) bytes for '\(name)'")

    // Log first 8 bytes as hex to detect BOM and other encoding issues
    let hexBytes = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    log("runnerModelFromIndex — first 8 bytes of '\(name)': [\(hexBytes)]")

    // Strip UTF-8 BOM (0xEF 0xBB 0xBF) — runner agent writes BOM-prefixed JSON on all platforms.
    // JSONDecoder is not BOM-aware and silently fails the entire decode if the BOM is present.
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    let hadBOM = data.prefix(3).elementsEqual(bom)
    if hadBOM {
        data = data.dropFirst(3)
        log("runnerModelFromIndex — BOM stripped for '\(name)', \(data.count) bytes remain")
    } else {
        log("runnerModelFromIndex — no BOM for '\(name)'")
    }

    // Log raw JSON string (first 400 chars) so we can see the actual keys
    if let raw = String(data: data, encoding: .utf8) {
        let preview = raw.count > 400 ? String(raw.prefix(400)) + "…" : raw
        log("runnerModelFromIndex — JSON preview for '\(name)': \(preview)")
    } else {
        log("runnerModelFromIndex — ⚠️ data is not valid UTF-8 for '\(name)'")
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

    // Also try a case-insensitive decode via JSONSerialization to cross-check
    // whether fields exist under different casings than our CodingKeys expect.
    if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        log("runnerModelFromIndex — raw JSON keys for '\(name)': \(rawDict.keys.sorted())")
        // Log the specific fields we care about under all their observed casings
        let keysOfInterest = ["gitHubUrl", "GitHubUrl", "githuburl", "github_url",
                              "AgentId", "agentId", "agent_id",
                              "Platform", "platform",
                              "PlatformArchitecture", "platformArchitecture", "platform_architecture"]
        for key in keysOfInterest {
            if let val = rawDict[key] {
                log("runnerModelFromIndex — '\(name)' has key '\(key)' = \(val)")
            }
        }
    } else {
        log("runnerModelFromIndex — ⚠️ JSONSerialization failed for '\(name)'")
    }

    let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
    if json == nil {
        log("runnerModelFromIndex — ⚠️ JSONDecoder failed to decode RunnerJSON for '\(name)'")
    } else {
        log("runnerModelFromIndex — decoded for '\(name)': gitHubUrl=\(json?.gitHubUrl ?? "nil") agentId=\(json?.agentId.map(String.init) ?? "nil") platform=\(json?.platform ?? "nil") arch=\(json?.platformArchitecture ?? "nil") workFolder=\(json?.workFolder ?? "nil")")
    }

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
