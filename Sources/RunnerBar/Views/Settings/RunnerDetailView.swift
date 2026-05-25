// RunnerDetailView.swift
// RunnerBar
// swiftlint:disable file_header
import AppKit
import RunnerBarCore
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// #491: Scaffold + read-only info block
// #492: Editable config fields (labels, workFolder, autoUpdate, proxy)
// #493: Danger Zone (remove only)
// #532: Redesign — two-row header, slim info section, unified proxy card
// #533: OS/Arch + Version rows in Runner Info; Danger Zone always expanded
// Phase 8: .glassEffect for infoCard and Danger Zone on macOS 26+

// MARK: - Save state helper
/// Tracks the lifecycle of an async save operation for a single editable field.
private enum SaveState: Equatable {
    /// The field is idle and ready for editing.
    case idle
    /// A save request has been dispatched and is in flight.
    case saving
    /// The last save completed successfully.
    case success
    /// The last save failed; the associated value contains a human-readable error message.
    case failure(String)
}

// MARK: - Danger action
/// Represents a destructive action the user can trigger from the Danger Zone section.
private enum DangerAction: Identifiable, Equatable {
    /// Permanently de-registers and removes the runner.
    case remove

    /// Stable identifier used by SwiftUI's `sheet(item:)` presentation.
    var id: String { "remove" }

    /// Human-readable title displayed in the Danger Zone row and confirmation sheet.
    var title: String { "Remove runner" }

    /// Label shown on the primary confirmation button.
    var confirmLabel: String { "Remove" }

    /// When `true` the trigger button and confirmation text are rendered in danger red.
    var destructive: Bool { true }
}

// swiftlint:disable:next type_body_length
/// Detail screen for a single self-hosted runner: displays info, editable config fields, and the Danger Zone.
struct RunnerDetailView: View {
    /// The runner model whose details and configuration this view displays and edits.
    let runner: RunnerModel
    /// Callback invoked when the user taps the back button to return to the Settings runner list.
    let onBack: () -> Void

    /// Reflects the runner's current running/stopped state; updated optimistically on start/stop.
    @State private var isRunning: Bool
    /// Human-readable status string derived from the runner model (e.g. "Online", "Offline").
    @State private var displayStatus: String
    /// Observes `LocalRunnerStore.shared` to refresh `isRunning` and `displayStatus` when the store changes.
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Editable field state (#492)
    /// Comma-separated custom labels string bound to the labels text field.
    @State private var labelsText: String
    /// Async save lifecycle state for the labels field.
    @State private var labelsSaveState: SaveState = .idle
    /// Work folder path string bound to the work-folder text field.
    @State private var workFolderText: String
    /// Async save lifecycle state for the work-folder field.
    @State private var workFolderSaveState: SaveState = .idle
    /// `true` = auto-update enabled (written to .runner JSON as disableUpdate: false)
    @State private var autoUpdate: Bool
    /// Async save lifecycle state for the auto-update toggle.
    @State private var autoUpdateSaveState: SaveState = .idle
    // #532: unified proxy card — single save state for URL + user + pass
    /// Proxy 