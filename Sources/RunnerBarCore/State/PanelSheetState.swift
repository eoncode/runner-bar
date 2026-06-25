// PanelSheetState.swift
// RunnerBarCore
import Observation

// MARK: - PanelSheetState

/// Process-lifetime sheet state owned by AppDelegate, not by SettingsView.
///
/// SwiftUI may clear a `.sheet(item:)` binding when the NSPopover window is
/// hidden because the attached sheet NSWindow is removed with its parent. This
/// object keeps the user's sheet intent outside the transient SettingsView
/// state so hiding the status-bar panel can be restored on the next open.
@MainActor
@Observable
final class PanelSheetState {
    /// The runner currently selected for the runner detail sheet.
    var editingRunner: RunnerModel?

    /// Backing store for captureTransientHideState() — persists sheet intent
    /// across NSPopover hide/show cycles. See type doc for NSPopover teardown context.
    private var runnerSheetSnapshot: RunnerModel?

    /// Captures the current runner sheet before hiding the popover.
    func captureTransientHideState() {
        runnerSheetSnapshot = editingRunner
    }

    /// Restores the runner sheet after the popover has been shown again.
    func restoreTransientHideStateIfNeeded() {
        // Only restore if no sheet is already active — prevents overwriting a runner set after the snapshot was captured.
        guard editingRunner == nil, let runnerSheetSnapshot else { return }
        editingRunner = runnerSheetSnapshot
        self.runnerSheetSnapshot = nil
    }

    /// Clears all runner sheet state for explicit close/reset paths.
    func clearRunnerSheet() {
        editingRunner = nil
        runnerSheetSnapshot = nil
    }
}
