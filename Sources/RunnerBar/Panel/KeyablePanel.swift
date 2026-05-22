import AppKit

// MARK: - KeyablePanel
//
// ⚠️ TEXT INPUT FIX (#525) — DO NOT REMOVE THIS CLASS.
//
// WHY THIS EXISTS:
// NSPanel with .nonactivatingPanel overrides canBecomeKey to return false.
// This is the AppKit contract: a non-activating panel intentionally never
// steals focus from the frontmost application.
// The side-effect is that NSTextField (and SwiftUI TextField backed by it)
// never receives first-responder, making all text fields silently non-editable.
//
// FIX:
// KeyablePanel is a minimal NSPanel subclass. It adds a single `wantsKey`
// flag. canBecomeKey returns true only when `wantsKey == true`, so the panel
// only becomes key for views that contain TextFields (settings, runner detail,
// scope detail). All read-only views leave wantsKey = false, preserving the
// non-activating behaviour everywhere else.
//
// USAGE IN AppDelegate:
//   panel.wantsKey = true   — before navigating to a text-input view
//   panel.makeKeyAndOrderFront(nil) — promotes panel to key window
//   panel.wantsKey = false  — in closePanel(), resets for next open
//
// ❌ NEVER replace KeyablePanel with plain NSPanel — text fields break again.
// ❌ NEVER set wantsKey = true globally — that makes the panel steal focus
//    from the frontmost app whenever it is shown, defeating .nonactivatingPanel.
// ❌ NEVER make this class private or fileprivate — AppDelegate+Navigation.swift
//    accesses `panel: KeyablePanel?` from a separate file; the type must be
//    at least internal so both files can reference it without a visibility error.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
final class KeyablePanel: NSPanel {
    /// Set to true immediately before navigating to a view that contains TextFields.
    /// Reset to false in closePanel().
    var wantsKey = false

    override var canBecomeKey: Bool { wantsKey }
}
