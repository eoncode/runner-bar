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

// MARK: - gh binary path helper

/// Returns the path to the `gh` CLI binary from a known safe allowlist.
///
/// Checks candidate paths in priority order (Apple Silicon Homebrew first,
/// then Intel Homebrew, then system-level). Returns `nil` when `gh` is not
/// installed at any of the known locations.
///
/// ⚠️ SECURITY: Never resolve `gh` via `PATH` — an attacker-controlled PATH
/// could redirect execution to a malicious binary. Only absolute, allowlisted
/// paths are checked here.
func ghBinaryPath() -> String? {
    let candidates = [
        "/opt/homebrew/bin/gh",  // Apple Silicon Homebrew (default prefix)
        "/usr/local/bin/gh",     // Intel Homebrew (legacy prefix)
        "/usr/bin/gh"            // System-level install
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
