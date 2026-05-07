import AppKit

/// Creates a 16×16 `NSImage` showing a filled circle whose colour reflects `status`.
///
/// Colour mapping:
/// - `.allOnline`   → system green
/// - `.someOffline` → system orange
/// - `.allOffline`  → system red
///
/// The circle is inset by 2 pt on each side (`insetBy(dx: dy: )`) so it sits
/// comfortably inside the 16 pt status bar button square without clipping at
/// the edges on any display density.
///
/// `isTemplate = false` prevents AppKit from converting the image to a
/// monochrome template rendering, which would discard the colour signal.
func makeStatusIcon(for status: AggregateStatus) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
        let color: NSColor
        switch status {
        case .allOnline:   color = .systemGreen
        case .someOffline: color = .systemOrange
        case .allOffline:  color = .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        return true
    }
    image.isTemplate = false  // preserve colour — do NOT set to true
    return image
}
