# NSPopover Without Jump Issues

Using a raw `NSPopover` for the RunnerBar panel causes a noticeable visual "jump" on show because the popover arrow animates from the wrong origin on the first display. The fix is to use an `NSPanel` instead (see `status-bar-window.md`), but if you do need an `NSPopover`, apply the mitigations below.

## Root Cause

`NSPopover` calculates its frame relative to its `positioningRect` at presentation time. If the rect is not precisely aligned to the status item button's frame in screen coordinates, AppKit snaps the popover to the nearest valid anchor, causing a jump.

## Mitigations

### 1. Use the button's bounds as the positioning rect

```swift
popover.show(
    relativeTo: button.bounds,
    of: button,
    preferredEdge: .minY
)
```

Do **not** convert the rect to screen coordinates yourself — `NSPopover` expects window coordinates.

### 2. Set `animates = false` during initial show

```swift
let wasAnimating = popover.animates
popover.animates = false
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
popover.animates = wasAnimating
```

This eliminates the jump entirely on first open; re-enable animation for subsequent shows if desired.

### 3. Pin to the correct screen

If you have a multi-monitor setup, ensure the `NSPopover` is shown on the screen that contains the status item by checking `button.window?.screen`.

## Preferred Solution

Use `NSPanel` (non-activating) as described in `status-bar-window.md`. It gives full control over positioning and avoids all `NSPopover` frame-calculation quirks.
