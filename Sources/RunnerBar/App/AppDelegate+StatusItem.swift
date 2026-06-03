// AppDelegate+StatusItem.swift
// RunnerBar
import AppKit
import RunnerBarCore

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
    /// ❌ NEVER read RunnerStore.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists; use menuBarImage(for:).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    func updateStatusIcon() {
        statusItem?.button?.image = menuBarImage(for: RunnerStore.shared.aggregateStatus)
    }

    // MARK: Image helper

    /// Returns the SF Symbol image for the given aggregate status.
    ///
    /// Uses a double-fallback chain to guarantee a non-nil `NSImage`:
    /// 1. `status.symbolName` — the correct SF Symbol for the current status.
    /// 2. `"circle"` — a safe generic fallback if the symbol name is unavailable
    ///    (e.g. running on an older OS that doesn’t have the symbol).
    /// 3. `NSImage()` — an empty image as a last resort to avoid a nil crash
    ///    when assigning to `NSStatusBarButton.image`.
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            ?? NSImage()
    }
}
