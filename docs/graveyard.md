# NSOpenPanel / Popover Dismiss — Fix Graveyard

This document records every approach attempted to fix the bug where the
popover dismisses when the user clicks inside the NSOpenPanel file picker
(issue #1193). Each entry documents what was tried, the theory behind it,
and exactly why it failed.

---

## Bug Summary

**Flow:** NSPopover → SwiftUI SettingsView → `.sheet` → ScopeEditSheet →
"Browse for folder" button → `openFolderPicker()` → NSOpenPanel.

**Symptom:** Clicking inside the NSOpenPanel file picker in any area that
falls outside the popover's frame causes the popover (and the sheet) to
dismiss immediately.

**Affected versions:** Introduced in or around the week of 2026-06-01.
Used to work before that.

---

## Attempt 1 — #1186 (2026-06-07): `NSApp.modalWindow` + `NSApp.windows` guards

**Theory:** The global mouse-event monitor calls `hidePanel()` when a click
lands outside the popover frame. Adding guards for `NSApp.modalWindow != nil`
(covers NSOpenPanel modal sessions) and `NSApp.windows.contains { $0.frame.contains(screenLoc) }`
(covers other app-owned windows) should catch the NSOpenPanel click.

**What happened:** Did not fix the bug.

**Why it failed:**
- `picker.begin { }` is asynchronous and free-floating. It never starts a
  modal run loop, so `NSApp.modalWindow` is always `nil` while the picker
  is open. The modal guard is permanently inactive.
- `NSApp.windows` only contains windows created directly by the app.
  `NSOpenPanel` is a system-managed window and never appears in that array.
  So the `inOtherAppWindow` guard is also permanently inactive.
- Both guards are structurally blind to this specific NSOpenPanel usage.

---

## Attempt 2 — #1195 commit 1 (2026-06-08): Switch to `.transient` behavior

**Theory:** `NSPopover.behavior = .transient` hands dismiss control to
AppKit natively. The assumption was that AppKit's native dismiss logic
would be aware of system panels (NSOpenPanel) spawned by the app and
not dismiss the popover while they are active — since AppKit owns both.

**Also removed:** The entire manual `NSEvent` global monitor and
`NSWorkspace` observer, since `.transient` was expected to replace both.

**What happened:** Tested on device — **did not fix the bug**. The popover
still dismissed on every click inside the file picker.

**Why it failed:**
- Apple's documentation for `.transient` states: *"The system will close
  the popover when the user interacts with user interface elements in the
  window containing the popover's positioning view."*
- For a menu bar app the popover's positioning view lives in the status bar
  button's window (or effectively no regular window at all). `.transient`
  has no special awareness of NSOpenPanel — it just closes on any outside
  interaction, full stop.
- The assumption that AppKit would "know" about its own NSOpenPanel was wrong.

---

## Attempt 3 — #1195 commit 2 (2026-06-08): `beginSheetModal` ← CURRENT

**Theory:** The real problem is that `picker.begin { }` opens NSOpenPanel
as a free-floating window that is invisible to every inspection mechanism
we have. If we instead attach NSOpenPanel as a sheet to the popover's own
backing window using `picker.beginSheetModal(for: popoverWindow)`, it
appears in `popoverWindow.sheets`. The event monitor already has a working
`inSheet` guard that checks `popoverWindow.sheets` — so no monitor changes
are needed at all.

**Changes:**
- `AppDelegate+PanelSetup.swift`: reverted back to `.applicationDefined`.
- `AppDelegate.swift`: full event monitor and workspace observer restored,
  with dense logging added throughout so the dismiss decision is visible
  in the console on every click.
- `ScopeDetailView.swift`: `openFolderPicker()` switches from
  `picker.begin { }` to `picker.beginSheetModal(for: popoverWindow)`,
  attaching the picker as a sheet to the popover window.

**Status:** In testing.

**Known risk:** `beginSheetModal` requires a valid `NSWindow` reference at
call time. We obtain it via `NSApp.keyWindow` (the popover is key when the
button is tapped) with a guard so we fall back to `begin { }` if the window
is unexpectedly nil — preserving the old behaviour rather than silently
doing nothing.

---

## Attempt 4 — #1195 commit 3 (2026-06-08): `isFilePickerActive` flag + `popoverShouldClose` guard

**Theory:** `beginSheetModal` (Attempt 3) required a valid `NSWindow` reference at call
time obtained via `NSApp.keyWindow`. In practice the sheet attachment either failed
or the picker still opened free-floating. The new approach adds a boolean flag
`isFilePickerActive` to `AppDelegate`. `ScopeDetailView.openFolderPicker()` sets it
`true` before calling `picker.begin { }` and clears it `false` in the completion
handler. `AppDelegate+PanelSetup.popoverShouldClose(_:)` returns `false` while the
flag is `true`, directly blocking AppKit from dismissing the popover.

**Changes:**
- `AppDelegate.swift`: added `var isFilePickerActive = false` (line 122).
- `AppDelegate+PanelSetup.swift`: `popoverShouldClose` now guards on
  `!isFilePickerActive` and logs when the close is blocked.
- `ScopeDetailView.swift`: `openFolderPicker()` sets/clears the flag around
  `picker.begin { }`.
- Reverted back to plain `picker.begin { }` (free-floating) since the flag
  makes sheet attachment unnecessary.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 15:13 CEST.

**Why it failed:**
`popoverShouldClose(_:)` is **only called when `behavior = .applicationDefined`**.
At the time of this attempt the popover was still set to `.transient` (left
over from Attempt 2). With `.transient`, AppKit never consults the delegate —
it closes the popover directly, bypassing `popoverShouldClose` entirely.
The `isFilePickerActive` flag and the delegate guard were structurally dead
code. The comment in `AppDelegate+PanelSetup.swift` line 48 even stated
"popoverShouldClose always returns true. AppKit is never blocked" — that was
written for the `.transient` world and proved the mechanism was inert.

---

## Attempt 5 — #1195 (2026-06-08 15:18 CEST): `.applicationDefined` + `isFilePickerActive` flag

**Theory:** Attempt 4 had the right mechanism (`isFilePickerActive` flag +
`popoverShouldClose` guard) but the wrong behavior mode. `popoverShouldClose`
is only consulted by AppKit when `behavior = .applicationDefined`. Switching
back to `.applicationDefined` and keeping the flag should finally work:
when the user taps inside the NSOpenPanel, AppKit asks `popoverShouldClose`,
we return `false`, the popover stays open.

**Changes:**
- `AppDelegate+PanelSetup.swift`: `newPopover.behavior = .applicationDefined`
  (was `.transient`). Updated the POPOVER BEHAVIOR comment block to reflect
  the correct reasoning.
- `docs/graveyard.md`: Attempt 4 marked failed with root cause explanation.
- No changes to `ScopeDetailView.swift` or `AppDelegate.swift` — the
  `isFilePickerActive` flag and `popoverShouldClose` guard from Attempt 4
  are correct and remain in place.

**Status:** Built and deployed — **in testing as of 2026-06-08 15:18 CEST**.

**Known risk:** `.applicationDefined` requires the manual NSEvent global
monitor and NSWorkspace observer to handle outside-click-hide and
app-switch-hide. These were restored in Attempt 3/4 and are present.
If they were accidentally removed again, the popover would never close.

---

## Attempt 6 — #1195 (2026-06-08 15:53 CEST): Move `isFilePickerActive = true` before `NSApp.activate`

**Theory:** Attempt 5 had the right mechanism (`.applicationDefined` + `isFilePickerActive` flag +
`workspaceObserver` guard + `outsideClickMonitor` guard) but a subtle ordering bug.
In `openFolderPicker()` the call sequence was:

1. `NSApp.activate(ignoringOtherApps: true)` ← fires `didActivateApplicationNotification` **synchronously on main**
2. `delegate?.isFilePickerActive = true` ← **too late** — observer already ran with flag = false
3. `picker.begin { }` ← panel opens

Because `NSApp.activate` dispatches the workspace notification on `.main` immediately,
the `workspaceObserver` closure ran with `isFilePickerActive == false`, saw `panelIsOpen == true`,
passed both guards, and called `hidePanel()` — collapsing the app before the flag was ever set.
Same race applies to the `outsideClickMonitor` if any click arrives between steps 1 and 2.

**Fix:** Swap the order — set `isFilePickerActive = true` **before** calling `NSApp.activate`.
Now both the workspace notification and any immediate click events see the flag as `true`
and bail out of `hidePanel()` before it runs.

**Changes:**
- `ScopeDetailView.swift` `openFolderPicker()`: moved `delegate?.isFilePickerActive = true`
  to before `NSApp.activate(ignoringOtherApps: true)`. Updated comment to explain why.
- `docs/graveyard.md`: this entry.

**Status:** ❌ FAILED — confirmed on device 2026-06-08 16:04 CEST.

**Why it failed:**
The Swift 6 compiler emitted `warning: main actor-isolated property 'isFilePickerActive'
can not be referenced from a Sendable closure` for both the `outsideClickMonitor` and
`workspaceObserver` closures. These closures are non-isolated `Sendable` contexts;
Swift cannot guarantee they read `isFilePickerActive` on the `@MainActor`. The
ordering fix (set flag before `NSApp.activate`) was correct but irrelevant — the
closures were reading a potentially-stale or un-isolated copy of the property
regardless of when it was set.

---

## Attempt 7 — #1195 (2026-06-08 16:04 CEST): `Task { @MainActor }` hop in both closures

**Theory:** Both `outsideClickMonitor` and `workspaceObserver` closures are
non-isolated `Sendable` contexts. Swift 6 warns that reading `@MainActor`-isolated
properties (`isFilePickerActive`, `panelIsOpen`) from them is unsafe — the value
may be stale or read off the main actor entirely. Wrapping the body of each closure
in `Task { @MainActor [weak self] in ... }` forces evaluation onto the main actor,
ensuring the flag read is sequenced correctly after `isFilePickerActive = true`.

**Changes:**
- `AppDelegate.swift` `openPanel()`: wrapped `outsideClickMonitor` closure body
  in `Task { @MainActor [weak self] in ... }`.
- `AppDelegate.swift` `openPanel()`: wrapped `workspaceObserver` closure body
  in `Task { @MainActor [weak self] in ... }`.
- Both changes eliminate the Swift 6 actor-isolation warnings — build is now
  warning-free for these properties.
- `docs/graveyard.md`: Attempt 6 marked failed with root cause explanation.

**Status:** In testing as of 2026-06-08 16:04 CEST.

**Known risk:** `Task { @MainActor }` schedules asynchronously on the main actor
cooperative queue. If a click arrives and the task hasn't run yet, `isFilePickerActive`
may still read `false` in a pathological timing window. This is extremely unlikely
since `isFilePickerActive = true` is set synchronously on main before the picker
opens — but if it recurs, the next step is `@MainActor` annotation on the closures
directly or moving to `DispatchQueue.main.sync`.

---

## Reading list / references

- https://ohanaware.com/swift/macOSOpenPanelSheet.html — documents the
  `beginSheetModal` approach for SwiftUI macOS sheet + open panel
- https://gist.github.com/bardigolriz/aa1f58b4e235cb5ea7b89afaa9977f89 —
  event monitor pattern for `.applicationDefined` menu bar popovers
- Apple docs: NSPopover.Behavior.transient — confirms .transient scope is
  limited to the window containing the positioning view
- Issue #1193 — original bug report with screenshot
- Issue #1195 — root cause analysis and fix tracking
