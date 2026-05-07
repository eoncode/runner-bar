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
final class LocalRunnerStore: ObservableObject {
    // MARK: Shared singleton

    static let shared = LocalRunnerStore()

    // MARK: Published state

    /// The list of locally-discovered runners. Empty until the first scan completes.
    @Published private(set) var runners: [RunnerModel] = []

    /// `true` while a background scan is in progress.
    @Published private(set) var isScanning: Bool = false

    // MARK: Private

    private let scanner = LocalRunnerScanner()
    private let queue = DispatchQueue(label: "dev.eonist.runnerbar.localrunnerstore", qos: .userInitiated)

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Triggers a fresh scan on a background thread. The published `runners`
    /// array is updated on the main thread when the scan finishes.
    func refresh() {
        guard !isScanning else { return }
        DispatchQueue.main.async { self.isScanning = true }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.scanner.scan()
            DispatchQueue.main.async {
                self.runners = result
                self.isScanning = false
            }
        }
    }
}
