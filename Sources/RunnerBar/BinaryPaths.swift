import Foundation

// MARK: - BinaryPaths

/// Fixed macOS system binary paths used throughout the app.
/// All paths are intentionally hard-coded: these are canonical macOS system
/// locations that cannot vary per-user and must not be configurable.
enum BinaryPaths {
    /// `/bin/zsh` — used by `shell()` to run synchronous shell commands.
    static let zsh = "/bin/zsh" // NOSONAR S1075 — fixed macOS system binary path
    /// `/bin/launchctl` — used by `RunnerLifecycleService` to start/stop services.
    static let launchctl = "/bin/launchctl" // NOSONAR S1075 — fixed macOS system binary path
    /// `/usr/bin/unzip` — always present on macOS; used by `unzipLogs`.
    static let unzip = "/usr/bin/unzip" // NOSONAR S1075 — fixed macOS system binary path
}
