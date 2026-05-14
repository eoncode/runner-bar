import Foundation

// MARK: - BinaryPaths

/// Centralised constants for system binary paths used throughout the app.
/// Avoids hard-coded URI literals (SonarCloud S1075) and makes path
/// changes easy to find.
enum BinaryPaths {
    /// The system zsh shell, used by `shell()` to run arbitrary commands.
    static let zsh = "/bin/zsh"
    /// The launchd control CLI, used by `RunnerLifecycleService`.
    static let launchctl = "/bin/launchctl"
    /// The system unzip binary, always available on macOS, used by `unzipLogs`.
    static let unzip = "/usr/bin/unzip"
}
