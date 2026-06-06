# Status Bar App Position Warning

macOS does not guarantee a fixed position for status bar items. If the menu bar is crowded, the system may hide items behind the Control Center overflow chevron ("»").

## Detection

RunnerBar detects when its own status item has been pushed offscreen:

```swift
if statusItem.button?.superview == nil {
    // Item is hidden — show an onboarding nudge
}
```

## User Guidance

When the item is hidden, display an `NSAlert` or in-app banner directing the user to:
1. Reduce the number of menu bar extras.
2. Use **System Settings → Control Center** to pin RunnerBar.
3. Hold **Command (⌘)** and drag menu bar items to reorder them.

## Menu Bar Extra Space

Keep the status item's button image small (16 × 16 pt) to minimise the chance of overflow on compact displays.
