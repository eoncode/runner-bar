import AppKit

/// Creates a 16×16 `NSImage` showing a filled circle whose colour reflects `status`.
///
/// Colour mapping:
/// - `.allOnline` → system green
/// - `.someOffline` → system orange
/// - `.allOffline` → system red
///
/// `isTemplate = false` prevents AppKit from discarding the colour signal.
func makeStatusIcon(for status: AggregateStatus) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false, drawingHandler: { rect in
        let color: NSColor
        switch status {
        case .allOnline: color = .systemGreen
        case .someOffline: color = .systemOrange
        case .allOffline: color = .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        return true
    })
    image.isTemplate = false
    return image
}
