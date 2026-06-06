<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# interesting. nspopover with dynamic width and with out side jumping issues. whats the secret to this. because i tried this before for days. and never got it to work.

The secret is one rule: **never call `popover.show()` more than once per open**. That's the only thing that moves the anchor. `contentSize` alone never does.

Here's the full mental model:

## How NSPopover positioning actually works

`NSPopover` has two completely separate concepts:

1. **Anchor** — set once by `show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`. This pins the arrow to the status bar button. AppKit remembers this forever for the lifetime of that show session.
2. **Content size** — controlled by `popover.contentSize`. This is just a rectangle resize. AppKit grows/shrinks the popover body around the fixed anchor point. The arrow never moves.

The lateral jump you saw before was almost certainly caused by one of these mistakes:


| What was done | Why it jumps |
| :-- | :-- |
| Calling `popover.show()` again on every resize | `show()` re-runs the full anchor calculation — it picks a new screen position from scratch based on current `button.bounds` and the new size |
| Using `NSPopover.behavior = .transient` with size changes | Transient behavior can close and re-show automatically in some AppKit paths |
| Setting `contentSize` *before* `show()` with a wrong size | Popover opens at the wrong size, then KVO fires and `show()` is called again to "reposition" |
| Using `NSWindow.setFrame()` directly on the popover's window | That bypasses AppKit's popover geometry and the anchor is recalculated on the next event loop tick |

## What the current implementation does differently

```swift
// openPanel() — called ONCE per open
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// KVO fires whenever SwiftUI layout changes
popover.contentSize = NSSize(width: newW, height: newH)  // NO show() call
```

`contentSize` is documented by Apple as: *"The popover's content size… changes to the content size will be animated when the popover is shown."*  — it's a pure resize, no repositioning. The anchor is owned by the `positioningView`/`positioningRect` pair set at `show()` time and is only recalculated if you call `show()` again.[^1]

## The `animates = false` detail

With `animates = true` (the default), every `contentSize` update triggers a Core Animation resize that takes ~200ms. During that animation window, if another `preferredContentSize` KVO fires (which SwiftUI can do several times in one layout pass), you get overlapping animations and the popover appears to stutter or jump. `animates = false` makes the resize instantaneous and idempotent — rapid KVO updates just snap to the latest size with no visual artifact.

## Why it failed before

The most likely culprit: the old `NSPanel` code called `resizeAndRepositionPanel()` which used `panel.setFrame(_:display:animate:)`. On `NSPanel`, position and size are always coupled in `setFrame` — you literally cannot resize without repositioning. With `NSPopover.contentSize` they are completely decoupled by design.

<div align="center">⁂</div>

[^1]: https://developer.apple.com/documentation/appkit/nspopover/contentsize
