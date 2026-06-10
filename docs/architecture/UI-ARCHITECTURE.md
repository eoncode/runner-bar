# RunnerBar — Architecture Reference

This document captures architectural decisions and regression guards that are
enforced inline in the source as single-line comments. **Do not remove** the
corresponding inline annotations without updating this file.

---

## Panel Lifecycle — NSPopover (as of fix/#1017)

> Previously NSPanel. Changed in fix/#1017 to fix rounded corners under SwiftUI .sheet.
> Regression guard ref: issues #377, #375, #376, #52–#57, #321, #370, #1017
> See also: `AppDelegate.swift`, `AppDelegate+Navigation.swift`, `AppDelegate+PanelSetup.swift`

### Why NSPopover instead of NSPanel

`NSPanel` with a custom `CAShapeLayer` mask (used to draw the arrow + rounded
corners) loses its rounded corners whenever a SwiftUI `.sheet` is presented as
a child `NSWindow`. AppKit's sheet attachment path modifies the parent window's
`CALayer` tree, discarding the mask. The `SettingsView` (and any other view with
a `.sheet`) produced rectangular corners on the popover.

`NSPopover` uses `NSPopoverWindowFrame`, a dedicated window class whose chrome
is drawn by the window-server compositor — completely unaffected by sheet
attachment. Rounded corners survive `.sheet` natively with zero extra code.

### How the popover is positioned

1. `NSPopover` with `animates=false`, `behavior=.applicationDefined`.
2. Shown via `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`.
   The arrow anchors to the button **once** at `show()` time and is never moved.
3. Size is driven by KVO on `NSHostingController.preferredContentSize`.
   Both width AND height are updated via `popover.contentSize`.
   ⚠️ Do NOT call `popover.show()` again on resize — that re-anchors and jumps.
4. Width is clamped to `[minWidth..maxWidth]` from screen bounds.
5. Dismiss: `popover.performClose(nil)` via `NSEvent` global monitor
   + `NSWorkspace` app-switch notification.

### Critical invariants

- ❌ NEVER re-call `popover.show()` on resize.
- ❌ NEVER revert to `NSPanel` without understanding the `.sheet` corner regression.
- ❌ NEVER call `popover.performClose()` while a sheet is open without first ordering out via `hidePopoverWindowsPreservingSheets()` — see §SheetOrphans below.

---

## Sheet Orphans — How the Final Architecture Prevents Them §SheetOrphans

> Regression guard ref: issue #1017  
> See also: `AppDelegate.swift` `closePanel()`, `hidePanel()`,
>           `hidePopoverWindowsPreservingSheets()`, `restorePopoverWindowsPreservingSheetsIfNeeded()`

### The problem

When `NSPopover.performClose()` is called while a SwiftUI `.sheet` is presented,
the sheet's backing `NSWindow` (a child of the popover window added via
`NSWindow.beginSheet`) is **not** automatically removed by AppKit. It becomes
an **orphan**: the window is still visible and still intercepts all mouse events,
but has no SwiftUI view tree driving it. The result is the app appearing completely
frozen — clicks land on the invisible orphan sheet window, not on the popover content.

### What was tried and failed (B1 / B2 / B3)

1. **`popoverShouldClose` returning `false` when `hasActiveSheet`** — blocks the
   user from interacting with other apps. The popover cannot be dismissed at all
   while a sheet is open. Discarded.

2. **Preserving `hostingController.rootView` across close + keeping savedNavState
   = .settings, then calling `validatedView(.settings)` on re-open** — this calls
   `settingsView()` which constructs a **brand new `SettingsView` struct**. Swift
   `@State` lives inside the View value type; it is initialised fresh on every
   new struct construction. `showAddScopeSheet`, `selectedScopeEntry` etc. are
   all reset to their defaults. The sheet disappears, and the orphaned sheet
   `NSWindow` from before close is still attached — SettingsView is frozen.

3. **Calling `endSheet(_:)` on all child windows before `performClose()` (`dismissSheets()`)** —
   this correctly removes the orphan, but also destroys the sheet's SwiftUI
   `@State`. On re-open the user is back at a blank `SettingsView` with the sheet
   gone. Acceptable for `closePanel()` (explicit dismiss), but unacceptable for
   `hidePanel()` (outside-tap / workspace-switch), where the user expects to
   return to exactly what they were doing.

### The final fix — order out, don't close

`hidePanel()` calls `hidePopoverWindowsPreservingSheets()` when `hasActiveSheet`
is true. This **orders the popover window out** (`orderOut(nil)`) without calling
`performClose()`, leaving the sheet `NSWindow` fully attached and the SwiftUI
`@State` intact. On re-open, `restorePopoverWindowsPreservingSheetsIfNeeded()`
calls `orderFront(nil)` on the same window — the sheet re-appears exactly as the
user left it.

`closePanel()` (explicit dismiss — Escape / back nav) never has a live sheet
because the user can only trigger explicit close from the main view or settings
header, both of which require the sheet to already be dismissed. `hasActiveSheet`
is false at that point, so `performClose()` is safe.

### Sheet state after re-open (explicit close path)

Sheet `@State` (e.g. `showAddScopeSheet = true`) **cannot** be preserved across
an explicit close/open cycle. `@State` lives in the SwiftUI view value type and
is reset when a new view is constructed. `savedNavState = .settings` is preserved
so re-opening navigates back to `SettingsView` (interactive, no sheet open). This
is the correct and only viable behaviour for the explicit-close path.

- ❌ NEVER try to "restore" sheet state by keeping the old rootView on explicit close.
- ❌ NEVER try to "restore" sheet state by passing sheet-open flags as init params.
- ❌ NEVER call `performClose()` from `hidePanel()` when `hasActiveSheet` is true — use `hidePopoverWindowsPreservingSheets()` instead.
- ❌ NEVER add `endSheet(_:)` / `dismissSheets()` to `hidePanel()` — it destroys sheet `@State` and was the discarded B3 approach.

---

## `panelVisibilityState` and `wrapEnv()`

> Regression guard ref: issue #377  
> See also: `AppDelegate.swift`, `PanelMainView.swift`

`panelVisibilityState: PanelVisibilityState` is an `ObservableObject` that
mirrors `panelIsOpen`. It is injected into every SwiftUI view hierarchy via
`wrapEnv()` so views can react to open/close without a direct reference to
`AppDelegate`.

- ❌ NEVER remove `panelVisibilityState`.
- ❌ NEVER remove `.environmentObject(panelVisibilityState)` from `wrapEnv()`.
- ❌ NEVER pass panel open state as a plain `Bool` prop to `PanelMainView`.

---

## `@MainActor` isolation on `AppDelegate`

> Regression guard ref: Swift 6 concurrency migration  
> See also: `AppDelegate.swift`, `AppDelegate+Navigation.swift`

`AppDelegate` is annotated `@MainActor`. This gives the Swift 6 compiler static
proof that all methods and stored properties are main-thread-only, eliminating
the need for runtime `DispatchQueue.main` assertions throughout.

The `nonisolated` blocking helper `enrichStepsIfNeeded` in
`AppDelegate+Navigation.swift` is intentionally exempt — it performs blocking
network I/O and is always dispatched onto `DispatchQueue.global()`.

- ❌ NEVER remove `@MainActor` from the `AppDelegate` class declaration.
- ❌ NEVER remove `nonisolated` from `enrichStepsIfNeeded`.

---

## Nav-state persistence across panel close/open

> Regression guard ref: issue #385  
> See also: `AppDelegate.swift` `closePanel()`

`savedNavState` is preserved across close so `openPanel()`'s `validatedView`
path navigates back to the same view on re-open. On close, `rootView` is always
reset to `mainView()` (so the SwiftUI tree is fresh), but `savedNavState` is
kept — `openPanel()` reads it and calls `navigate(to: validatedView(for: saved))`.

- ❌ NEVER clear `savedNavState` inside `closePanel()` or `hidePanel()`.
- ❌ NEVER try to preserve sheet @State across an **explicit close** (`closePanel()`) — see §SheetOrphans.
- Sheet @State IS preserved across `hidePanel()` (outside-tap / workspace-switch) via `hidePopoverWindowsPreservingSheets()` — this is intentional.

---

## OAuth URL handling

> Ref: issue #597  
> See also: `AppDelegate.swift` `application(_:open:)`

The `application(_:open:)` delegate searches the **full** `urls` array for the
`runnerbar://oauth/callback` URL rather than assuming `urls.first`. macOS may
deliver multiple URLs and the OAuth callback may not be first, which would leave
the sign-in spinner stuck indefinitely.

---

## `KeyablePanel` access level

> See also: `KeyablePanel.swift`, `AppDelegate.swift`

`KeyablePanel` must be `internal` (not `private` or `fileprivate`). 
`AppDelegate+Navigation.swift` accesses `panel: KeyablePanel?` from a separate
file, and Swift `private` does not cross file boundaries.
