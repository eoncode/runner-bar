import Combine
import Foundation

// MARK: - LocalRunnerStore

@MainActor
final class LocalRunnerStore: ObservableObject {
    static let shared = LocalRunnerStore()
    private init() {
        // No custom initialisation needed; singleton uses default property values.
    }

    @Published var runners: [RunnerModel] = []
    @Published var isScanning: Bool = false

    private let scanner  = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared

    // MARK: - Refresh

    func refresh() {
        log("LocalRunnerStore > refresh() called — isScanning=\(isScanning) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore > refresh() SKIPPED — already scanning")
            return
        }
        isScanning = true
        log("LocalRunnerStore > refresh() — isScanning set to true, dispatching background scan")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            log("LocalRunnerStore > refresh() background — starting scanner.scan()")
            let scanned = self.scanner.scan()
            let summary = scanned.map { "\($0.runnerName)(isRunning=\($0.isRunning))" }.joined(separator: ", ")
            log("LocalRunnerStore > refresh() background — scanner.scan() returned \(scanned.count) runner(s): [\(summary)]")

            let token = githubToken()
            var enriched = scanned
            if token != nil {
                log("LocalRunnerStore > refresh() background — token present, calling enricher")
                enriched = self.enricher.enrich(runners: scanned)
                let enrichedSummary = enriched.map { r -> String in
                    let st = r.githubStatus ?? "nil"
                    let w = r.lifecycleWarning ?? "none"
                    return "\(r.runnerName)(isRunning=\(r.isRunning),status=\(st),warning=\(w))"
                }.joined(separator: ", ")
                log("LocalRunnerStore > refresh() background — enricher returned \(enriched.count) runner(s): [\(enrichedSummary)]")
            } else {
                log("LocalRunnerStore > refresh() background — no token, skipping enricher")
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("LocalRunnerStore > refresh() main — assigning \(enriched.count) runner(s) to self.runners (was \(self.runners.count))")
                self.runners = enriched
                self.isScanning = false
                log("LocalRunnerStore > refresh() main — done. runners.count=\(self.runners.count) isScanning=\(self.isScanning)")
            }
        }
    }

    // MARK: - Optimistic mutations

    func optimisticallyRemove(_ runnerName: String) {
        log("LocalRunnerStore > optimisticallyRemove — runnerName=\(runnerName) runners.count was \(runners.count)")
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore > optimisticallyRemove — done, runners.count=\(runners.count)")
    }

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
