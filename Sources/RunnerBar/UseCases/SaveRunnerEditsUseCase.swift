// SaveRunnerEditsUseCase.swift
// RunnerBar
// SaveRunnerEditsUseCase has moved to RunnerBarCore/Runner/SaveRunnerEditsUseCase.swift.
// This file is intentionally empty — kept so git history shows the migration path.
import RunnerBarCore

// MARK: - DefaultRunnerLabelsService

/// Live conformance of `RunnerLabelsService` that delegates to `patchRunnerLabels`.
/// Lives in RunnerBar (not Core) because `patchRunnerLabels` is an app-layer free function
/// that depends on `GitHubURLSessionTransport`, which cannot be a RunnerBarCore dependency.
struct DefaultRunnerLabelsService: RunnerLabelsService {
    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        await patchRunnerLabels(scope: scope, runnerID: runnerID, labels: labels)
    }
}
