import Foundation

// MARK: - BinaryPaths

/// Centralised constants for system binary paths used throughout the app.
/// Avoids S1075 (URI hard-coded) violations and makes path changes a single-point edit.
enum BinaryPaths {
    /// The zsh shell binary — used by `shell()` to execute commands.
    static let zsh = "/bin/zsh"
    /// The launchctl binary — used by `RunnerLifecycleService` for service control.
    static let launchctl = "/bin/launchctl"
    /// The unzip binary — used by `LogFetcher.unzipLogs` to extract run log ZIPs.
    static let unzip = "/usr/bin/unzip"
}
