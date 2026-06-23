// WorkflowActionsUseCase.swift
// RunnerBar
import RunnerBarCore

// MARK: - WorkflowActionsUseCase

/// Encapsulates all mutating workflow and job actions, routing them through
/// the injected transport layer.
///
/// Declared as a `Sendable` struct so it can be safely stored as a
/// `let` constant on `@MainActor`-isolated `ViewModifier` types and captured
/// across actor boundaries without triggering Swift 6 sendability warnings.
///
/// Each method is `nonisolated` so the `withTaskGroup` fan-out runs on the
/// cooperative thread pool rather than blocking the caller's actor executor
/// (P18). `@concurrent` is not a standard Swift attribute and was removed
/// per code review — `nonisolated` is the correct spelling for this intent.
struct WorkflowActionsUseCase: Sendable {

    // MARK: - Dependencies

    /// Injected transport. Defaults to the module-level `sharedGitHubTransport`
    /// shim so production callers need no extra wiring (P7).
    private let transport: any GitHubTransportProtocol

    // MARK: - Init

    init(transport: any GitHubTransportProtocol = sharedGitHubTransport) {
        self.transport = transport
    }

    // MARK: - Workflow mutations

    /// Re-runs only the failed jobs for each run ID in `scope` in parallel.
    nonisolated
    @discardableResult
    func rerunFailed(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.post(
                        "repos/\(scope)/actions/runs/\(id)/rerun-failed-jobs",
                        body: nil,
                        timeout: 30
                    ) != nil
                }
            }
            return await group.allSatisfy { $0 }
        }
    }

    /// Re-runs all jobs for each run ID in `scope` in parallel.
    nonisolated
    @discardableResult
    func rerunAll(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.post(
                        "repos/\(scope)/actions/runs/\(id)/rerun",
                        body: nil,
                        timeout: 30
                    ) != nil
                }
            }
            return await group.allSatisfy { $0 }
        }
    }

    /// Cancels each run ID in `scope` in parallel.
    nonisolated
    @discardableResult
    func cancel(runIDs: [Int], scope: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for id in runIDs {
                group.addTask {
                    await transport.cancelRun(runID: id, scope: scope)
                }
            }
            return await group.allSatisfy { $0 }
        }
    }

    // MARK: - Job mutations

    /// Re-runs a single job by ID.
    nonisolated
    @discardableResult
    func rerunJob(jobID: Int, scope: String) async -> Bool {
        await transport.post(
            "repos/\(scope)/actions/jobs/\(jobID)/rerun",
            body: nil,
            timeout: 30
        ) != nil
    }
}
