import Combine
import Foundation

// MARK: - LocalRunnerStore

/// An `ObservableObject` that drives the Local Runners section of `SettingsView`.
///
/// Wraps `LocalRunnerScanner` and exposes the result as a published array so
/// SwiftUI views automatically re-render when the scan completes or is refreshed.
///
/// **Threading:** scanning is dispatched to a background queue to avoid blocking
/// the main thread. `runners` is always updated on the main queue.
///
/// **Phase 4:** After the local scan, `RunnerStatusEnricher` is called on the
/// same background thread to enrich each runner with live GitHub API status
/// (online/offline/busy). Enrichment is skipped silently when no GitHub token
/// is present, preserving Phase 1 behaviour for unauthenticated users.
final class LocalRunnerStore: ObservableObject {
    // MARK: Shared singleton

    static let shared = LocalRunnerStore()

    // MARK: Published state

    /// The list of locally-discovered runners. Empty until the first scan completes.
    @Published private(set) var runners: [RunnerModel] = []

    /// `true` while a background scan is in progress.
    ///
    /// Defaults to `false` so that the `guard !isScanning` check in `refresh()`
    /// does not block the very first scan triggered from `.onAppear`.
    @Published private(set) var isScanning: Bool = false

    // MARK: Private

    private let scanner = LocalRunnerScanner()
    private let enricher = RunnerStatusEnricher.shared
    private let queue = DispatchQueue(
        label: "dev.eonist.runnerbar.localrunnerstore",
        qos: .userInitiated
    )

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Triggers a fresh scan on a background thread. The published `runners`
    /// array is updated on the main thread when the scan and optional enrichment
    /// finish.
    ///
    /// `@MainActor` enforces the main-thread call-site contract at compile time.
    /// `isScanning = true` is set synchronously before dispatching background
    /// work to close the race window where two rapid calls could both pass the guard.
    ///
    /// ⚠️ REGRESSION GUARD: `isScanning = true` must remain synchronous here.
    @MainActor
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            guard let self else { return }
            // Phase 1: local scan
            var result = self.scanner.scan()
            // Phase 4: enrich with live GitHub API status (skipped if no token)
            if githubToken() != nil {
                result = self.enricher.enrich(runners: result)
            }
            DispatchQueue.main.async {
                self.runners = result
                self.isScanning = false
            }
        }
    }
}
