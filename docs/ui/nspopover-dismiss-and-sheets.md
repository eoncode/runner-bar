# NSPopover Architecture — Dismiss, Sheets, and File Pickers

This document describes how RunBot's NSPopover works, why it is built
the way it is, and how PR #1195 solved the problem of the popover
dismissing when the user clicks inside an NSOpenPanel file picker.

For the full history of failed attempts see `docs/graveyard.md`.

---

## The problem

RunBot uses an NSPopover as its main UI surface. Inside the popover,
SwiftUI presents a Settings flow via `.sheet`, and inside that sheet the
user can open a folder picker (NSOpenPanel) to select a path.

NSOpenPanel opens as a separate window. When the user clicks inside it,
the click lands outside the popover's frame. RunBot's global
`NSEvent` monitor sees an outside click and calls `hidePanel()`,
dismissing both the popover and the sheet before the user has picked anything.

This is the bug fixed by PR #1195.

---

## Why NSPopover (not NSPanel)

RunBot switched from NSPanel to NSPopover in PR #1017 for one specific
reason: **rounded corners survive sheet attachment**.

NSPanel with a custom `CAShapeLayer` mask or `masksToBounds` loses its
rounded corners whenever AppKit attaches a SwiftUI `.sheet` as a child
`NSWindow`. AppKit's sheet attachment path modifies the parent window's
`CALayer` tree, discarding any mask we set.

NSPopover uses `NSPopoverWindowFrame` — a dedicated window class whose
chrome is composited by the window server, not by our `CALayer` setup.
Rounded corners survive sheet attachment natively. No workaround needed.

---

## Popover configuration

```
behavior  = .applicationDefined
animates  = false
delegate  = AppDelegate
```

### `.applicationDefined` — why not `.transient`

`.transient` was the first thing tried (Attempt 2 in `graveyard.md`).
It failed immediately and on-device.

Apple's documentation for `.transient` says the system closes the popover
"when the user interacts with user interface elements in the window
containing the popover's positioning view." For a menu bar app the
positioning view lives in the status bar button's window — effectively
no regular window at all. `.transient` has **no awareness of NSOpenPanel**.
It simply closes on any outside interaction, full stop.

More critically: with `.transient` AppKit **bypasses the global NSEvent
monitor entirely**. It closes the popover internally without ever delivering
the click event to our handler. This made every subsequent guard and flag
we tried unreachable dead code (Attempts 4, 5, 6, 7).

`.applicationDefined` keeps dismiss control in our hands. AppKit consults
`popoverShouldClose(_:)` before dismissing, and our global event monitor
receives every outside click so we can decide what to do with it.

### Re-asserting behavior before every `show()`

AppKit **latches** `behavior` at `popover.show()` time, not at assignment
time. If the value ever resets between sessions, the next open silently
runs as `.transient` — the monitor never fires (Attempt 7 root cause:
zero `outsideClickMonitor FIRED` log lines).

The fix is to re-assert both `popover.behavior = .applicationDefined` and
`popover.delegate = self` immediately before every `popover.show()` call
in `openPanel()`. This is the same pattern already used for
`shouldHideAnchor`.

---

## How the dismiss pipeline works

```
Status bar click
    └─> togglePanel()
            └─> openPanel()
                    ├─> popover.show()
                    ├─> install outsideClickMonitor  (NSEvent global monitor)
                    └─> install workspaceObserver    (NSWorkspace notification)

Outside click
    └─> outsideClickMonitor fires
            ├─> guard panelIsOpen          — skip if already closed
            ├─> guard !hasActiveSheet      — ← THE KEY GUARD (see below)
            ├─> guard click not in popover frame
            └─> hidePanel()

App switch
    └─> workspaceObserver fires
            ├─> guard panelIsOpen
            ├─> guard !hasActiveSheet
            ├─> guard activatedApp != NSRunningApplication.current
            └─> hidePanel()

Any close path
    └─> tearDownOpenState()
            ├─> removes outsideClickMonitor
            └─> removes workspaceObserver
```

### `popoverShouldClose` is not a control point

`popoverShouldClose(_:)` always returns `true`. AppKit is never blocked
here. All dismiss control goes through `outsideClickMonitor` and
`workspaceObserver`. Trying to use `popoverShouldClose` as the gate was
Attempts 4 and 5 — both failed for other reasons — and the current
architecture deliberately avoids it.

---

## The fix — `hasActiveSheet` + `beginSheetModal`

This is the core of PR #1195. Two things work together:

### 1. `beginSheetModal(for: popoverWindow)`

NSOpenPanel is opened using `picker.beginSheetModal(for: hostWindow)`
instead of `picker.begin { }` or `picker.runModal()`.

`beginSheetModal` attaches NSOpenPanel as a **child sheet of the popover's
own `NSWindow`**. This makes it appear in `popoverWindow.sheets`.

`picker.begin { }` opens NSOpenPanel as a free-floating window that is
completely invisible to every guard mechanism we have:
- `NSApp.modalWindow` is `nil` (it's not a modal session)
- `NSApp.windows` doesn't contain it (it's system-managed)
- `popoverWindow.sheets` doesn't contain it (it's not attached)

`beginSheetModal` fixes all three at once by making the picker a structural
part of the popover's window hierarchy.

### 2. `guard !self.hasActiveSheet`

```swift
var hasActiveSheet: Bool {
    popover?.contentViewController?.view.window?.sheets.isEmpty == false
}
```

Both `outsideClickMonitor` and `workspaceObserver` guard on this before
calling `hidePanel()`. If any sheet is attached to the popover window —
NSOpenPanel, SwiftUI `.sheet()`, or any future modal — the monitor returns
immediately. No dismiss.

**Why this is better than a flag (`isFilePickerActive`):**

Attempts 4–9 all tried a boolean flag. Every one failed:

| Failure mode | Attempts affected |
|---|---|
| Flag set after `NSApp.activate()` fires the workspace notification (ordering race) | 6 |
| Flag read in non-isolated closure — Swift 6 stale-value warning | 6 |
| Flag threaded through `Task { @MainActor }` hop — new async timing window | 7 |
| Second call site (`AddRunnerSheet`) missed entirely — flag never set | 9 |

`hasActiveSheet` has none of these failure modes:
- It's a direct structural check on `popoverWindow.sheets` — a fact about
  the window hierarchy, not a manually managed flag.
- It can't be missed at new call sites because no call site sets it.
- It has no timing dependency — the sheet either is or isn't in
  `popoverWindow.sheets` at the moment the guard runs.
- It works automatically for SwiftUI `.sheet()` too, not just NSOpenPanel.

---

## `WindowGrabber` — reliable `NSWindow` reference for `beginSheetModal`

`beginSheetModal(for:)` requires a valid `NSWindow` at call time.
The earlier approaches used `NSApp.keyWindow ?? NSApp.mainWindow` which is
unreliable — key window can be `nil` or point to the wrong window depending
on focus state.

`WindowGrabber` is a zero-size `NSViewRepresentable` that captures the
hosting `NSWindow` via `viewDidMoveToWindow()`:

```swift
// In ScopeDetailView / AddRunnerSheet:
.background(WindowGrabber { w in
    if hostWindow == nil, let w { hostWindow = w }
})
```

`viewDidMoveToWindow()` fires when the SwiftUI view is first inserted into
the view hierarchy — before any user interaction is possible. By the time
the user can tap "Browse for folder", `hostWindow` is already set to the
correct `NSWindow`.

**Gotcha:** The `nil`-on-removal case. `viewDidMoveToWindow()` also fires
with `window = nil` when the view is removed from the hierarchy. The call
site guards `if hostWindow == nil, let w` — once set it never updates.
This is correct for the current lifecycle (short-lived modal sheet always
attached to the same popover window). If a future view can be re-attached
to a different window, add `guard let window else { return }` inside
`WindowGrabber` itself and remove the `if hostWindow == nil` guard at the
call site.

---

## Sheet state across hide/show

When the user taps outside while a SwiftUI `.sheet` is open, `hidePanel()`
is called. The goal is that re-opening the status bar icon should restore
the popover with the sheet still open.

`hidePanel()` does **not** call `dismissSheets()` and does **not** reset
`rootView`. `popover.performClose()` closes `NSPopoverWindowFrame` and all
child windows together — they're removed from screen but the
`NSHostingController` and its SwiftUI tree stay alive with `@State`
preserved. On re-open, `popover.show()` re-attaches the same controller
and SwiftUI re-presents the sheet automatically because the binding is
still `true`.

`closePanel()` is different — called on explicit user dismissal (Escape,
back navigation). It resets `rootView = mainView()` so the next open
starts fresh.

```
❌ NEVER add dismissSheets() to hidePanel()
❌ NEVER reset hostingController.rootView inside hidePanel()
```

---

## Pros and cons of this approach

### Pros

- **No timing dependency.** `hasActiveSheet` is a synchronous structural
  check. No async hops, no flag ordering, no race conditions.
- **Zero call-site boilerplate.** Adding a new sheet or picker requires no
  AppDelegate changes — as long as it uses `beginSheetModal(for:)`, the
  guard fires automatically.
- **Works for all sheet types.** SwiftUI `.sheet()`, NSOpenPanel via
  `beginSheetModal`, and any future `NSWindow` attached as a sheet are all
  covered by the same guard.
- **Dismiss control is explicit and auditable.** Every decision to call
  `hidePanel()` flows through two guards whose logs are visible in console.
  No AppKit black-box dismiss.
- **Sheet state survives hide/show.** The SwiftUI tree is never destroyed;
  `@State` is preserved across hide/show cycles.

### Cons

- **Manual monitor management.** `.applicationDefined` means we own
  install and teardown of `outsideClickMonitor` and `workspaceObserver`.
  If `tearDownOpenState()` is ever not called on a close path, monitors
  leak and fire indefinitely. The current code calls it on every path;
  this must be maintained.
- **Re-assert discipline.** `behavior` and `delegate` must be re-asserted
  before every `popover.show()`. Forgetting this (Attempt 7's root cause)
  silently reverts to `.transient` and the monitor stops delivering events.
- **`beginSheetModal` required everywhere.** Any future NSOpenPanel call
  site that uses `picker.begin { }` or `runModal()` will bypass `hasActiveSheet`
  and re-introduce the bug. The `❌ NEVER` rules in `AppDelegate+PanelSetup.swift`
  document this explicitly.
- **`NSPopoverWindowFrame` is private AppKit.** The rounded-corner behaviour
  depends on this internal class not changing. Not App Store distributed,
  so acceptable.

---

## Gotchas and rules

```
❌ NEVER use picker.begin { }            — free-floating, invisible to hasActiveSheet
❌ NEVER use picker.runModal()           — same reason
✅ ALWAYS use picker.beginSheetModal(for: hostWindow)

❌ NEVER call popover.show() on resize   — re-anchors the arrow; use contentSize only
❌ NEVER omit behavior re-assert before show() — AppKit latches at show-time
❌ NEVER omit delegate re-assert before show() — same reason

❌ NEVER add dismissSheets() to hidePanel()
❌ NEVER reset hostingController.rootView in hidePanel()

❌ NEVER remove tearDownOpenState() from any close path — monitor leak
❌ NEVER inline teardown back into AppDelegate.swift
```
