import Foundation

// MARK: - BinaryPaths

/// Centralised constants for system binary paths used throughout the app.
/// Avoids hard-coded URI literals flagged by SonarCloud S1075.
///
/// All paths point to macOS system binaries that are guaranteed present on
/// any supported macOS version. The `gh` CLI binary is intentionally absent
/// here — it is resolved dynamically via `ghBinaryPath()` in GitHub.swift
/// because it can be installed in multiple locations.
enum BinaryPaths {
    /// `/bin/zsh` — the default macOS shell used by `shell(_:timeout:)`.
    static let zsh = "/bin/zsh"
    /// `/bin/launchctl` — used by `RunnerLifecycleService` to start/stop services.
    static let launchctl = "/bin/launchctl"
    /// `/usr/bin/unzip` — always present on macOS; used by `unzipLogs`.
    static let unzip = "/usr/bin/unzip"
}
