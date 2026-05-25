// GHBinaryLocator.swift
// RunnerBarCore
import Foundation

/// Shared utility for locating the `gh` CLI binary on macOS.
public enum GHBinaryLocator {
    /// Candidate paths for the `gh` binary, covering Homebrew (Silicon & Intel) and system locations.
    private static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    /// Returns the absolute path to the `gh` binary if found and executable, otherwise `nil`.
    /// The search is re-evaluated on every call to pick up new installations without relaunching.
    public static func ghBinaryPath() -> String? {
        candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
