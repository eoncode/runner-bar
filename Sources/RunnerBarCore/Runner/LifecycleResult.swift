// LifecycleResult.swift
// RunnerBarCore
import Foundation

// MARK: - LifecycleResult

/// The result of a runner lifecycle operation (start or stop).
public enum LifecycleResult {
    /// The operation completed successfully.
    case success
    /// The runner installation is corrupt (e.g. missing `svc.sh`, wrong working directory).
    /// The caller should prompt the user to reinstall the runner.
    case corruptInstall
    /// The operation failed with a human-readable reason string.
    case failed(String)
}
