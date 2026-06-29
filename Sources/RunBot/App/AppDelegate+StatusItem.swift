// AppDelegate+StatusItem.swift
// RunBot
import AppKit
import RunBotCore

// MARK: - AppDelegate + Status Item
//
// Owns NSStatusItem creation, menu-bar icon updates, and the menuBarImage
// helper that maps AggregateStatus to the correct SF Symbol.
// Called once from applicationDidFinishLaunching via setupStatusItem().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupStatusItem() more than once.

/// Extension owning NSStatusItem creation, icon updates, and the `menuBarImage` helper.
extension AppDelegate {

    // MARK: Status item setup

    /// Creates the NSStatusItem, sets the initial icon, and wires the toggle action.
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = menuBarImage(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: Icon updates

    /// Updates the menu-bar icon to reflect the current aggregate runner status.
    /// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
    /// ❌ NEVER read RunnerPoller.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists; use menuBarImage(for:).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    func updateStatusIcon() {
        // `aggregateStatus` is derived from `runnerState.runners` which `RunnerPoller`
        // pushes to `RunnerState` via `MainActor.run` after every fetch cycle.
        let status = AggregateStatus(runners: runnerState.runners)
        statusItem?.button?.image = menuBarImage(for: status)
    }

    // MARK: Image helper

    /// Returns the SF Symbol image for the given aggregate status.
    ///
    /// Uses a double-fallback chain to guarantee a non-nil `NSImage`:
    /// 1. `status.symbolName` — the correct SF Symbol for the current status.
    /// 2. `"circle"` — a safe generic fallback if the symbol name is unavailable
    ///    (e.g. running on an older OS that doesn’t have the symbol).
    /// 3. `NSImage(named: "MenuBarFallback")` — a bundled asset that keeps the
    ///    status-bar icon visible even when all SF Symbols are unavailable;
    ///    falls back to `NSImage()` (empty/invisible) only if the asset is also missing.
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            ?? {
                #if DEBUG
                assertionFailure("MenuBarFallback asset missing from Assets.xcassets — add it to keep the status-bar icon visible on SF Symbol failure")
                #endif
                return NSImage(named: "MenuBarFallback")
            }()
            ?? NSImage()
    }
}
