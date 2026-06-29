# Status Bar Window Strategy

> **Last updated:** 2026-05-29  
> **Issue:** #1017 — SettingsView gets rectangular corners when a SwiftUI `.sheet` is presented

---

## The Core Problem

When a SwiftUI `.sheet` (e.g. `RunnerDetailPopover`, `ScopeEditSheet`, `AddRunnerSheet`) is
presented on top of `SettingsView`, the **parent window** — not the sheet — loses its rounded
corners and goes fully rectangular.

This is **not** a bug in RunBot's logic. It is a well-known consequence of how AppKit handles
sheet presentation on windows that rely on any form of *custom* corner radius.

### Why it happens

When AppKit calls `window.beginSheet(sheet)` it:
1. Adds the sheet as a child `NSWindow` via `addChildWindow(_:ordered:)` (or the newer
   `NSWindowAttachmentBehavior` path on macOS 14+).
2. To composite the two windows, it modifies the **parent window's `CALayer` tree** — in
   particular the `masksToBounds` and `mask` properties on the content view's backing layer.
3. Any `CAShapeLayer` mask or `cornerRadius + masksToBounds` that *you* set on that layer is
   removed or invalidated by AppKit as a side-effect.

This is documented nowhere publicly, but is confirmed by multiple developer reports:
- https://github.com/eoncode/run-bot/issues/1017
- https://stackoverflow.com/questions/62995489 (clear bg + borderless doesn't survive sheet)
- Electron issue #9159 (same root cause in a different runtime)

---

## What Has Been Tried and Why It Failed

### Attempt 1 — `CAShapeLayer` mask on `NSVisualEffectView` (original approach, `PanelChromeView`)

**What it did:** Drew a custom Bézier path (rounded rect + arrow tip) as a `CAShapeLayer` and
applied it as `fxView.layer.mask`.  
**Why it failed:** AppKit removes/replaces `layer.mask` on the parent window's content view
when a sheet is attached. The panel body went rectangular immediately on sheet presentation and
stayed rectangular until the sheet was dismissed.

### Attempt 2 — `contentView.layer.cornerRadius + masksToBounds` (PR #1017 first iteration)

**What it did:** Removed `PanelChromeView` and set `cornerRadius` + `masksToBounds` directly on
the `NSHostingController.view` (= the panel's content view layer).  
**Why it failed:** `masksToBounds = true` is precisely what AppKit modifies during sheet
attachment. Same result — corners go rectangular on sheet open. Also: `masksToBounds` clips child
`NSWindow`s' visual content, creating rendering artefacts.

### Attempt 3 — `backgroundColor = .clear + isOpaque = false` ("window-server native corners")

**What it did:** Made the panel fully transparent (no content view layer manipulation), relying
on the window server to draw native rounded corners on a borderless `NSPanel`.  
**Why it failed (observed):**
- The panel background became completely transparent — no glass, no vibrancy, no visual surface.
  `.background(.regularMaterial)` was added to `PanelMainView` in a follow-up commit but still
  did not restore the background.
- Corners **still** went rectangular when a sheet opened.
- **Root cause diagnosis:** A borderless `NSPanel` with `backgroundColor = .clear` does NOT get
  window-server native rounded corners. The "native rounded corners" behaviour only applies to
  windows that have a *standard* (non-borderless) style mask, or that use
  `NSWindow.styleMask = [.titled, .fullSizeContentView]`. A raw `[.borderless]` panel is a plain
  rectangle at the compositor level — no rounding applied by the window server regardless of
  `isOpaque`. The transparency just made the rectangle invisible, creating the illusion of
  rounding in the zero-sheet state, but the issue was never actually fixed.

### Attempt 4 — `.background(.regularMaterial)` on `PanelMainView`

**What it did:** Added `.background(.regularMaterial)` to the root VStack of `PanelMainView` to
restore glass vibrancy after `PanelChromeView` was removed.  
**Why it failed:** The `.regularMaterial` applied correctly but provided no rounding. Because
the window layer has no corner radius, the material renders as a plain rectangle. Also the
attached screenshot shows no visible background at all — the material may require the window's
`contentView` to have `wantsLayer = true` and a non-opaque background to composite correctly.

---

## Root Cause Summary

All attempts share the same flaw: they try to apply corner rounding *inside the window's view
hierarchy*. AppKit deliberately discards or overrides any such in-hierarchy clipping when a
sheet is presented.

**The only correct solution is to never let the parent window's own layers be responsible for
rounding.** Two viable paths exist:

---

## New Strategy: Use `NSPopover` Instead of `NSPanel` for the Main Window

### Why NSPopover is the right answer

`NSPopover` is the standard macOS mechanism for a status-bar panel. It:
- Has **native window-server rounded corners drawn by the compositor**, not by any layer.
- Uses a dedicated `NSPopoverWindowFrame` window class, which the AppKit sheet machinery
  **treats differently** — it does not invalidate the frame window's corners on sheet attachment.
- Automatically gets the correct vibrancy/glass background with zero configuration.
- Does not require any `CAShapeLayer`, `cornerRadius`, `masksToBounds`, or `clear` background.
- The `.sheet` modifier in SwiftUI works correctly against it because AppKit's sheet path for
  `NSPopover`-backed windows preserves the popover chrome.

This is exactly how **every well-maintained macOS status bar app** works:
- **Raycast** — uses `NSPopover` with a custom `NSPopoverBehavior`
- **Proxyman** — uses `NSPopover`
- **Hand Mirror, Lungo, Almighty** — use `NSPopover`
- The canonical Apple tutorial at https://developer.apple.com/tutorials/develop-in-swift/
  uses `NSPopover`
- The `fleetingpixels.com` and `capgemini.github.io` tutorials both use `NSPopover`

The original reason RunBot moved to `NSPanel` (#377) was to prevent **lateral panel jumps**
on content-size changes. That concern is legitimate but can be solved within `NSPopover` using:
1. `popover.contentSize` driven by `NSHostingController.preferredContentSize` (same KVO approach
   used today).
2. `popover.positioningRect` re-set on the same `NSStatusBarButton.bounds` each time — the
   popover anchor stays fixed; only the content size changes.

### What needs to change

| Current | Target |
|---|---|
| `KeyablePanel: NSPanel` with `.borderless` style | `NSPopover` with `NSHostingController` |
| Manual `setFrame()` in `resizeAndRepositionPanel()` | `popover.contentSize = controller.preferredContentSize` |
| Custom `panelTopY` anchor tracking | `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)` |
| `panel.level = .popUpMenu` | Not needed — `NSPopover` handles its own level |
| `eventMonitor` for outside click | `NSPopover.behavior = .transient` handles this |
| Sheet rounding broken | Sheet rounding works natively |
| No glass background | Automatic popover chrome |

### What stays the same

- All SwiftUI views (`PanelMainView`, `SettingsView`, all sheets) — zero changes
- `AppDelegate+Navigation.swift` view factories — zero changes
- `panelVisibilityState` / `PanelVisibilityState` — needs `isOpen` driven from `NSPopoverDelegate`
- `makeKeyForTextInput()` — replaces `panel.makeKeyAndOrderFront(nil)` with `NSApp.activate(ignoringOtherApps: true)`
- `closePanel()` / `hidePanel()` — replaces `panel.orderOut(nil)` with `popover.performClose(nil)`

### Known concern: lateral jumps (#377)

When SwiftUI reports a new `preferredContentSize`, `NSPopover` will briefly jump to the new
size. To mitigate:
- Do NOT animate the popover (`popover.animates = false`).
- Always re-show relative to the same `button.bounds` — the arrow anchor stays fixed.
- The jump is a single-frame reposition, identical to what `NSPanel.setFrame()` currently does.

### Fallback if NSPopover is insufficient

If the `NSPopover` path reintroduces the lateral jump issue intolerably, the second-best option
is to use a **titled, full-size content view `NSPanel`** instead of borderless:

```swift
let newPanel = KeyablePanel(
    contentRect: NSRect(x: 0, y: 0, width: initW, height: 300),
    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
newPanel.titleVisibility = .hidden
newPanel.titlebarAppearsTransparent = true
newPanel.standardWindowButton(.closeButton)?.isHidden = true
newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
newPanel.standardWindowButton(.zoomButton)?.isHidden = true
```

A `.titled + .fullSizeContentView` window **does** get native window-server rounded corners
(because macOS only rounds titled windows). With `titlebarAppearsTransparent + titleVisibility.hidden`
the title bar is invisible but the compositor-level rounding remains. This is how
apps like **Tot** and **Pockity** handle it.

---

## Implementation Plan (NSPopover path)

1. **`AppDelegate+PanelSetup.swift`** — replace `KeyablePanel` construction with `NSPopover`
   construction. Set `popover.contentViewController = controller`, `popover.animates = false`,
   `popover.behavior = .applicationDefined`.
2. **`AppDelegate.swift`** — replace `panel: KeyablePanel?` with `popover: NSPopover?`. Replace
   `openPanel()` with `showPopover()`, `closePanel()` with `closePopover()`.
3. **`AppDelegate+Navigation.swift`** — replace `makeKeyForTextInput()` call with
   `NSApp.activate(ignoringOtherApps: true)`.
4. **`KeyablePanel.swift`** — can be deleted or kept for a future fallback.
5. **`resizeAndRepositionPanel()`** — replace `setFrame()` with
   `popover.contentSize = newSize`. No panelTopY, no statusItemRect arithmetic.
6. **`eventMonitor`** — remove entirely (`NSPopover.behavior = .transient` handles outside click).
7. **`workspaceObserver`** — keep, replacing `hidePanel()` with `popover.performClose(nil)`.
8. **`PanelChromeView` / `PanelChrome.swift`** — already removed, leave as tombstone.
9. **`PanelMainView.swift`** — remove `.background(.regularMaterial)` if it was added as a
   workaround; NSPopover provides the background automatically.

---

*See also: `docs/ui/nspopover-dynamic-width.md` for the NSPopover sizing/anchor mental model.*
*See also: `docs/ui/popover-side-jump-prevention.md` for the definitive no-jumping checklist.*
