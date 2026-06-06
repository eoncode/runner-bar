# Status Bar Window

RunnerBar's primary UI surface is an `NSPanel`-based popover anchored to the menu bar status item.

## Architecture

- `StatusBarController` owns the `NSStatusItem` and manages show/hide logic.
- The panel is a `NSPanel` subclass with `styleMask: [.borderless, .nonactivatingPanel]` so it does not steal key focus from the active app.
- Content is rendered with a SwiftUI `NSHostingView` embedded in the panel's `contentView`.

## Show / Hide

```swift
func togglePopover() {
    if panel.isVisible {
        panel.orderOut(nil)
    } else {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
    }
}
```

## Positioning

The panel is repositioned every time it opens so it stays anchored below the status item even after display configuration changes:

```swift
func positionPanel() {
    guard let button = statusItem.button,
          let screen = button.window?.screen else { return }
    let buttonRect = button.convert(button.bounds, to: nil)
    let screenRect = button.window!.convertToScreen(buttonRect)
    let origin = NSPoint(
        x: screenRect.midX - panel.frame.width / 2,
        y: screenRect.minY - panel.frame.height
    )
    panel.setFrameOrigin(origin)
}
```

## Dismissal

The panel dismisses on:
- A second click on the status item
- Loss of key window status (`windowDidResignKey`)
- An explicit `closePopover()` call from within SwiftUI via an environment action
