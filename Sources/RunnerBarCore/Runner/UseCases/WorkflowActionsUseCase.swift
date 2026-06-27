// WorkflowActionsUseCase.swift
// RunnerBarCore
import Foundation

// MARK: - WorkflowActionsUseCase

/// Encapsulates all mutating workflow and job actions, routing them through
/// the injected transport layer.
///
/// Declared as a `Sendable` struct so it can be safely stored as a
/// `let` constant on `@MainActor`-isolated `ViewModifier` types and captured
/// across actor boundaries without triggering Swift 6 sendability warnings.
///
/// Methods are plain `func` with no isolation annotation. Because
/// `WorkflowActionsUseCase` is a non-actor `Sendable` struct, all methods
/// are already non-isolated and run on the cooperative thread pool when
/// called with `await` from inside a `Task { }` (P18).
///
/// Moved from `RunnerBarCore/UseCases/` to `RunnerBarCore/Runner/UseCases/` —
/// all mutations target GitHub Actions workflow and job objects within the runner domain.
public struct WorkflowActionsUseCase: Sendable {

    private let transport: any GitHubTransportProtocol

    public init(transport: any GitHubTransportProtocol = sharedGitHubTransport) {
        self.transport = transport
    }

    // MARK: - Workflow mutations

    /// Re-runs only the failed jobs for each run ID in `scope` in parallel.
    @discardableResult
    public func rerunFailed(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.post(
                        "repos/\(scope)/actions/runs/\(id)/rerun-failed-jobs",
                        body: nil, timeout: 30
                    ) != nil
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results.allSatisfy { $0 }
        }
    }

    /// Re-runs all jobs for each run ID in `scope` in parallel.
    @discardableResult
    public func rerunAll(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.post(
                        "repos/\(scope)/actions/runs/\(id)/rerun",
                        body: nil, timeout: 30
                    ) != nil
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results.allSatisfy { $0 }
        }
    }

    /// Cancels each run ID in `scope` in parallel.
    @discardableResult
    public func cancel(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.cancelRun(runID: id, scope: scope)
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results.allSatisfy { $0 }
        }
    }

    /// Re-runs a single job by ID.
    @discardableResult
    public func rerunJob(jobID: Int, scope: String) async -> Bool {
        await transport.post(
            "repos/\(scope)/actions/jobs/\(jobID)/rerun",
            body: nil, timeout: 30
        ) != nil
    }
}
