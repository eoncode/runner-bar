// RunnerViewModel.swift
// RunnerBar
import Foundation
import Observation

// MARK: - RunnerViewModel

// MARK: Protocol conformance
// `RunnerViewModel` satisfies `RunnerViewModelProtocol` structurally (all required
// properties are already declared below). The explicit conformance is declared here
// so the compiler verifies it and callers can use `RunnerViewModel` anywhere
// `any RunnerViewModelProtocol` is expected.
/// Declares that `RunnerViewModel` conforms to `RunnerViewModelProtocol`.
/// All required properties are defined on the main class body below.
extension RunnerViewModel: RunnerViewModelProtocol {}

/// Bridges `LocalRunnerStore` into observable properties consumed by SwiftUI views.
///
/// State is **pushed** into this view model by `LocalRunnerStore` via `await MainActor.run { }`.
/// GitHub runner/job/action state now lives in `RunnerState` and is written directly
/// by `RunnerPoller.applyFetchResult` — it no longer flows through this class.
/// No pull / Combine sinks required. The entire class is `@MainActor` because all
/// property mutations and reads must happen on the main thread for SwiftUI rendering.
@MainActor
@Observable
final class RunnerViewModel {
    // periphery:ignore
    /// ❌ Do not use. The single live instance is owned by `AppDelegate` as `observable`.
    ///
    /// Only `LocalRunnerStore` pushes state into `AppDelegate.observable`;
    /// this accessor is never updated and will silently return stale/empty data.
    /// Inject `RunnerViewModel` explicitly via the environment or constructor instead.
    @MainActor static var shared: RunnerViewModel {
        fatalError(
            "RunnerViewModel.shared must not be used. "
                + "The live instance is AppDelegate.observable — inject it via the environment "
                + "or pass it as a constructor argument."
        )
    }

    // MARK: - Observable state (pushed by LocalRunnerStore)
    /// Locally-installed runner agents discovered on this Mac.
    var localRunners: [RunnerModel] = []
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    var isLocalScanning: Bool = false
}
