// RunnerViewModelProtocol.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerViewModelProtocol

/// Push-receiver interface through which `LocalRunnerStore` delivers
/// its computed snapshots to the main-actor presentation layer.
///
/// The five GitHub API props (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`) moved to `RunnerState` in Step 3 and are no longer
/// part of this protocol (removed in Step 15).
///
/// Declaring the protocol in `RunnerBarCore` (rather than the app target) achieves two goals:
/// 1. `RunnerPoller` and `LocalRunnerStore` can reference it without importing AppKit or SwiftUI.
/// 2. Test doubles (`MockRunnerViewModel`) can be defined inside `RunnerBarCoreTests` and
///    passed into the actors without any app-target dependency.
///
/// **Direction of data flow:** stores *push* into the receiver; the receiver never pulls.
/// All mutations arrive on `@MainActor` via `await MainActor.run { }`.
@MainActor
public protocol RunnerViewModelProtocol: AnyObject, Sendable {
    // MARK: Pushed by LocalRunnerStore

    /// Locally-installed runner agents discovered on this Mac.
    var localRunners: [RunnerModel] { get set }
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    var isLocalScanning: Bool { get set }
}
