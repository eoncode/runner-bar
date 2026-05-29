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
- ❌ NEVER remove `dismissSheets()` from `closePanel()` or `hidePanel()` — see §SheetOrphans below.

---

## Sheet Orphans — Why dismissSheets() Must Run Before performClose() §SheetOrphans

> Regression guard ref: issue #1017  
> See also: `AppDelegate.swift` `closePanel()`, `hidePanel()`

### The problem

When `NSPopover.performClose()` is called while a SwiftUI `.sheet` is presented,
the sheet's backing `NSWindow` (a child of the popover window added via
`NSWindow.beginSheet`) is **not** automatically removed by AppKit. It becomes
an **orphan**: the window is still visible and still intercepts all mouse events,
but has no SwiftUI view tree driving it. The result is the app appearing completely
frozen — clicks land on the invisible orphan sheet window, not on the popover content.

### What was tried and failed

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

3. **Not resetting `hostingController.rootView` at all on close** — same result.
   The orphaned sheet NSWindow from the previous session blocks hit-testing
   regardless of what SwiftUI state we put in the hosting controller.

### The fix

Call `endSheet(_:)` on every sheet window **before** `performClose()`. This lets
AppKit synchronously remove the child sheet window from the window hierarchy
before the popover closes, preventing the orphan entirely.

```swift
private func dismissSheets() {
    guard let win = popover?.contentViewController?.view.window else { return }
    for sheet in win.sheets {
        win.endSheet(sheet)
    }
}
```

Call `dismissSheets()` at the top of both `closePanel()` and `hidePanel()`.

### Sheet state after re-open

Sheet `@State` (e.g. `showAddScopeSheet = true`) **cannot** be preserved across
a close/open cycle. `@State` lives in the SwiftUI view value type and is reset
when a new view is constructed. `savedNavState = .settings` is still preserved
so re-opening navigates back to `SettingsView` (interactive, no sheet). This is
the correct and only viable behaviour.

- ❌ NEVER try to "restore" sheet state by keeping the old rootView.
- ❌ NEVER try to "restore" sheet state by passing sheet-open flags as init params.
- ❌ NEVER remove `dismissSheets()` from `closePanel()` or `hidePanel()`.

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
- ❌ NEVER try to preserve sheet @State across close — see §SheetOrphans.

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
