// LocalRunnerStore.swift
// RunnerBar
import Combine
import Foundation
import RunnerBarCore

// MARK: - LocalRunnerStore

// swiftlint:disable type_body_length missing_docs
/// Manages LocalRunnerStore state and behaviour.
@MainActor
final class LocalRunnerStore: ObservableObject {
    /// The shared constant.
    static let shared = LocalRunnerStore()
    /// Private initialiser — use `shared`.
    private init() {}

    /// The runners property.
    @Published var runners: [RunnerModel] = []
    /// The isScanning property.
    @Published var isScanning: Bool = false

    /// The enricher constant.
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Refresh

    /// Performs the refresh operation.
    func refresh() {
        log("LocalRunnerStore > refresh() called — isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore > refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore > refresh() — isScanning set to true, dispatching background task")
        let enricher = self.enricher
        // TODO: restore runner auto-discovery from git (issue #982)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let token = githubToken()
            var enriched: [RunnerModel] = []
            if token != nil {
                log("LocalRunnerStore > refresh() background — token present, calling enricher")
                enriched = enricher.enrich(runners: [])
                log("LocalRunnerStore > refresh() background — enricher returned \(enriched.count) runner(s): [\(runnerEnrichedSummary(enriched))]")
            } else {
                log("LocalRunnerStore > refresh() background — no token, skipping enricher")
            }

            // Phase 3 (#591 / #948): collect CPU/MEM metrics for any runner whose
            // launchd service is active (isRunning == true), not only isBusy runners.
            applyMetrics(&enriched)

            DispatchQueue.main.async { [weak self, enriched] in
                guard let self else { return }
                log("LocalRunnerStore > refresh() main — assigning \(enriched.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done. runners.count=\(self.runners.count) isScanning=\(self.isScanning)")
            }
        }
    }

    // MARK: - Optimistic mutations

    /// Performs the optimisticallyRemove operation.
    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore > optimisticallyRemove — runnerName=\(runnerName) runners.count was \(runners.count)")
        runners.removeAll { $0.runnerName == runnerName }
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
        log("LocalRunnerStore > optimisticallySetRunning — FOUND at index \(idx), old isRunning=\(runners[idx].isRunning), setting to \(isRunning)")
        runners[idx].isRunning = isRunning
        runners[idx].lifecycleWarning = nil
        log("LocalRunnerStore > optimisticallySetRunning — cleared lifecycleWarning for \(runnerName)")
        objectWillChange.send()
        log("LocalRunnerStore > optimisticallySetRunning — done, runners.count=\(runners.count)")
    }

    /// Performs the setLifecycleWarning operation.
    func setLifecycleWarning(_ runnerName: String, warning: String?) {
        let w = warning ?? "nil"
        log("LocalRunnerStore > setLifecycleWarning called: runnerName=\(runnerName) warning=\(w)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore > setLifecycleWarning — NOT FOUND for \(runnerName)")
            return
        }
        log("LocalRunnerStore > setLifecycleWarning — FOUND at index \(idx), setting warning=\(w) on runner \(runnerName)")
        runners[idx].lifecycleWarning = warning
        objectWillChange.send()
        let displayStatus = runners[idx].displayStatus
        log("LocalRunnerStore > setLifecycleWarning — done for \(runnerName), displayStatus is now: \(displayStatus)")
    }
}
// swiftlint:enable type_body_length missing_docs

// MARK: - Private helpers (file-private, non-member to reduce class complexity)

/// Returns a compact enriched summary string: "name(isRunning, status, warning), …"
private func runnerEnrichedSummary(_ runners: [RunnerModel]) -> String {
    runners.map { r in
        let st = r.githubStatus ?? "nil"
        let w  = r.lifecycleWarning ?? "none"
        return "\(r.runnerName)(isRunning=\(r.isRunning),status=\(st),warning=\(w))"
    }.joined(separator: ", ")
}

/// Mutates each runner in `enriched` in-place to attach CPU/MEM metrics
/// for any runner whose launchd service is active (`isRunning == true`).
private func applyMetrics(_ enriched: inout [RunnerModel]) {
    for idx in enriched.indices {
        guard enriched[idx].isRunning, let installPath = enriched[idx].installPath else { continue }
        enriched[idx].metrics = metricsForRunner(installPath: installPath)
        log("LocalRunnerStore > applyMetrics — \(enriched[idx].runnerName): \(String(describing: enriched[idx].metrics))")
    }
}
