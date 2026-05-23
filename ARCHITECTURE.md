# RunnerBar — Architecture Reference

This document captures architectural decisions and regression guards that are
enforced inline in the source as single-line comments. **Do not remove** the
corresponding inline annotations without updating this file.

---

## Panel Lifecycle — NSPanel over NSPopover

> Regression guard ref: issues #377, #375, #376, #52–#57, #321, #370  
> See also: `AppDelegate.swift`, `AppDelegate+Navigation.swift`, `AppDelegate+PanelSetup.swift`

### Why NSPanel instead of NSPopover

`NSPopover` re-anchors on **any** `contentSize` change while it is visible.
This is documented, intentional AppKit behaviour — not a bug. Every attempt to
dynamically resize `NSPopover` while visible causes a lateral jump. Confirmed
across many issues and Stack Overflow threads (#14449945, #69877522).

`NSPanel` has no anchor concept. `setFrame()` while visible = zero jump, ever.

### How the panel is positioned

1. Panel is a borderless, non-activating `NSPanel`.
2. Position is computed from the status button's window frame (screen coords):
   - `statusItemRect = button.window!.frame` — already in screen coords
   - `panelX = statusItemRect.midX - contentW / 2` — re-centred each resize
   - `panelTopY = statusItemRect.minY - gap` — **locked at open time**
   - `y = max(visibleFrame.minY, panelTopY - totalH)` — clamped to screen
3. `arrowX = statusItemRect.midX - panel.frame.minX`
   - ❌ NEVER use `convertToScreen(button.frame)` — `button.frame` is button-local
4. `sizingOptions = .preferredContentSize`: KVO on `preferredContentSize`
   → `resizeAndRepositionPanel()` → `setFrame()`. Zero jump.
5. Dismiss: `NSEvent` global monitor + `NSWorkspace` app-switch notification.

### Critical invariants

- ❌ NEVER re-derive `panelTopY` from `statusItemRect` inside
  `resizeAndRepositionPanel()` — menu-bar hide/show shifts `statusItemRect.minY`,
  moving the panel under the notch.
- ❌ NEVER set `initPanelWidth > maxWidth`.
- ❌ NEVER restore `initPanelWidth` to 600.
- ❌ NEVER call `resizeAndRepositionPanel()` from a background thread.
- ❌ NEVER remove the `resizeAndRepositionPanel()` call from `navigate(to:)`.

### Chrome dimensions (match NSPopover exactly)

| Property | Value |
|----------|-------|
| arrowHeight | 9 pt |
| arrowWidth | 30 pt |
| cornerRadius | 10 pt |

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

When the panel closes, `savedNavState` is captured **before** `mainView()` is
called (which resets it), then restored so `openPanel()`'s `validatedView` path
can navigate back to the same view the user was on.

```swift
// In closePanel():
let preserved = self.savedNavState
self.hostingController?.rootView = self.mainView()
self.savedNavState = preserved
```

- ❌ NEVER replace the `hostingController?.rootView = mainView()` call with a
  no-op stub `PanelMainView` — this resets the SwiftUI view tree correctly.
- ❌ NEVER reorder the capture / reset / restore sequence.

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
