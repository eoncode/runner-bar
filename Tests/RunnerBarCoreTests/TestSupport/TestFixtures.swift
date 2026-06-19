// TestFixtures.swift
// RunnerBarCoreTests
// Shared test fixtures — extracted per #1446.
import Foundation
import RunnerBarCore

// MARK: - Constants

/// Stable install path used across test fixtures to avoid repeating a hardcoded URI literal.
internal let testRunnerInstallPath = "/tmp/runner" // NOSONAR — test-only fixture path

// MARK: - Factories

/// Creates a `RunnerModel` with sensible defaults for display-status and status-colour tests.
///
/// Extracted from `RunnerModelDisplayStatusTests` and `RunnerModelStatusColorTests`
/// where it was defined identically as a private helper in each suite (#1446).
func makeRunnerModel(
    isRunning: Bool,
    isBusy: Bool = false,
    githubStatus: RunnerStatus = .online,
    lifecycleWarning: String? = nil,
    workFolder: String? = nil
) -> RunnerModel {
    RunnerModel(
        runnerName: "test-runner",
        gitHubUrl: nil,
        agentId: nil,
        workFolder: workFolder,
        installPath: testRunnerInstallPath,
        isRunning: isRunning,
        githubStatus: githubStatus,
        isBusy: isBusy,
        lifecycleWarning: lifecycleWarning
    )
}
