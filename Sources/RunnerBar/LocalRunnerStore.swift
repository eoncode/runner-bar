import Combine
import Foundation

// MARK: - LocalRunnerStore

/// Singleton store that manages local runner discovery and publishes updates
/// to SwiftUI. Performs scans on a background thread to keep the UI responsive.
@MainActor
final class LocalRunnerStore: ObservableObject {
    /// Shared singleton instance.
    static let shared = LocalRunnerStore()

    /// The list of discovered local runners.
    @Published private(set) var runners: [RunnerModel] = []

    /// `true` while a scan is currently in progress.
    @Published private(set) var isScanning = false

    /// Internal scanner instance.
    private let scanner = LocalRunnerScanner()

    /// Background queue for performing file-system and process scans.
    private let queue = DispatchQueue(label: "com.eoncode.RunnerBar.LocalRunnerScanner", qos: .userInitiated)

    private init() {
        // Initial state is idle.
    }

    /// Triggers a fresh 3-source scan on a background thread.
    /// Prevents overlapping scans using the `isScanning` guard.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        queue.async { [weak self] in
            guard let self else { return }

            // Perform the blocking scan
            let results = self.scanner.scan()

            Task { @MainActor in
                self.runners = results
                self.isScanning = false
            }
        }
    }
}
