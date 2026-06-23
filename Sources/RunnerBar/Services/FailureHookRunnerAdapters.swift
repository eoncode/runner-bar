// FailureHookRunnerAdapters.swift
// RunnerBar
//
// Production adapters that bridge the `ScopePreferencesStore` actor and
// `TerminalLauncher` singleton to the protocols expected by
// `FailureHookRunnerUseCase`.
import Foundation
import RunnerBarCore

// MARK: - DefaultScopePreferencesStore

/// Forwards all protocol calls to `ScopePreferencesStore.shared`.
///
/// `ScopePreferencesStore` is itself an actor that conforms to
/// `ScopePreferencesStoreProtocol`, so the simplest production adapter
/// is just a typealias to the shared singleton. This wrapper exists only
/// to preserve the `DefaultScopePreferencesStore` name used at call sites
/// in `FailureHookRunner` without touching that file. (#1538)
typealias DefaultScopePreferencesStore = ScopePreferencesStore

// MARK: - DefaultTerminalLauncher

/// Forwards `open(_:)` to `TerminalLauncher.open(command:)`.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
///
/// `@MainActor` is required because `NSAppleScript` (used inside
/// `TerminalLauncher.open`) must run on the main thread. (#1538)
struct DefaultTerminalLauncher: TerminalLauncherProtocol {
    /// Forwards to `TerminalLauncher.open(command:)`. Must be called on `@MainActor`.
    @MainActor
    func open(_ command: String) {
        TerminalLauncher.open(command: command)
    }
}
