# Dark Mode & Light Mode Support

Runner Bar supports both **Light Mode** and **Dark Mode**, following the macOS system appearance automatically. There is no user-facing toggle to force a specific mode — the app defers entirely to the system setting.

---

## Implementation Overview

Appearance adaptation is handled at three distinct layers:

### 1. `PanelChromeView` — Explicit AppKit Check (`PanelChrome.swift`)

The custom `NSView` subclass that draws the panel body and arrow tip uses `effectiveAppearance` to manually detect the active color scheme and applies the appropriate background fill:

```swift
let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
let fill: NSColor = isDark
    ? NSColor(white: 0.18, alpha: 0.01)
    : NSColor(white: 0.95, alpha: 0.01)
```

This is the standard AppKit approach for manual dark/light branching.

### 2. `NSVisualEffectView` — Automatic Material Adaptation (`PanelChrome.swift`)

The panel background is an `NSVisualEffectView` configured with:

```swift
view.material = .popover
view.blendingMode = .behindWindow
view.state = .active
```

The `.popover` material automatically resolves to a light frosted-glass blur in Light Mode and a dark tinted blur in Dark Mode — no manual intervention needed. This matches the native `NSPopover` appearance exactly.

### 3. SwiftUI Views — Semantic Colors (all view files)

All SwiftUI views (`PopoverMainView`, `StepLogView`, `PopoverMainViewSubviews`, etc.) exclusively use **semantic system colors** that adapt automatically:

- `.primary` / `.secondary` — text and icons
- `.green`, `.red`, `.yellow` — status indicators
- `Color.secondary.opacity(0.12)` — subtle backgrounds

SwiftUI resolves these to the correct light/dark values at render time with no manual color branching required.

---

## Summary

| Layer | File | Mechanism | Adaptive? |
|---|---|---|---|
| `PanelChromeView` (AppKit) | `PanelChrome.swift` | `effectiveAppearance.bestMatch` | ✅ Explicit manual check |
| `NSVisualEffectView` material | `PanelChrome.swift` | `.popover` + `.behindWindow` | ✅ Automatic |
| SwiftUI views | All view files | Semantic colors (`.primary`, `.secondary`, etc.) | ✅ Automatic |

---

## Notes

- There is **no hardcoded `NSColor` or `Color(hex:)`** usage found in the UI layer — all colors are semantic or derived from appearance checks.
- The `NSVisualEffectView` approach is intentional and well-guarded in comments — switching the material away from `.popover` is explicitly prohibited in code comments to prevent visual regressions.
- The app targets macOS 13+ (Ventura), where both `.darkAqua` and `.aqua` appearance names are fully supported.
