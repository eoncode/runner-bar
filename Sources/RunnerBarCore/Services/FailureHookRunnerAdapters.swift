// FailureHookRunnerAdapters.swift
// RunnerBar
//
// Production adapters that bridge dependencies to the protocols expected by
// `FailureHookRunnerUseCase`.
import Foundation

// MARK: - DefaultTerminalLauncher

/// Forwards `open(_:)` to `TerminalLauncher.open(command:)`.
/// Used as the production dependency for `FailureHookRunnerUseCase`.
///
/// `@MainActor` is required because `NSAppleScript` (used inside
/// `TerminalLauncher.open`) must run on the main thread. (#1538)
///
/// Moved from `RunnerBar` to `RunnerBarCore` in #1623.
public struct DefaultTerminalLauncher: TerminalLauncherProtocol {
    /// Creates a new `DefaultTerminalLauncher` instance.
    public init() {}
    /// Forwards to `TerminalLauncher.open(command:)`. Must be called on `@MainActor`.
    @MainActor
    public func open(_ command: String) {
        TerminalLauncher.open(command: command)
    }
}
