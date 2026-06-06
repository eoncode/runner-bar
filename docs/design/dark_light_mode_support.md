# Dark & Light Mode Support

RunnerBar supports both macOS appearance modes. Views observe `colorScheme` from the environment and adapt colors accordingly.

## Key Guidelines

- Use semantic colors (`Color(.labelColor)`, `Color(.secondaryLabelColor)`) wherever possible so the system handles adaptation automatically.
- For custom colors, define separate values for light and dark in `Assets.xcassets` using the Appearances slot.
- Avoid hard-coded hex values in SwiftUI views; always go through a design token or asset catalog entry.
- Test every new view in both Light and Dark mode in the Xcode canvas before submitting a PR.

## SwiftUI Environment

```swift
@Environment(\.colorScheme) private var colorScheme

var body: some View {
    Text("Hello")
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
}
```

## AppKit Interop

For `NSView`-backed components use `effectiveAppearance` and override `updateLayer()` / `drawRect(_:)` to re-draw when the appearance changes.

```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
}
```
