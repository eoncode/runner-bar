import AppKit

// swiftlint:disable operator_usage_whitespace vertical_whitespace_opening_braces
/// Renders the coloured status icon shown in the menu bar and popover rows.
struct StatusIcon {
    let status: String
    let conclusion: String?

    /// Icon character for the current status/conclusion.
    var icon: String {
        switch conclusion {
        case "success": return "✓"
        case "failure": return "✗"
        case "cancelled": return "⊘"
        case "skipped": return "⊘"
        case "timed_out": return "✗"
        case "action_required": return "!"
        default:
            switch status {
            case "in_progress": return "▶"
            case "queued": return "·"
            default: return "·"
            }
        }
    }

    /// Foreground colour for the icon.
    var color: NSColor {
        switch conclusion {
        case "success": return .systemGreen
        case "failure", "timed_out": return .systemRed
        case "action_required": return .systemOrange
        case "cancelled", "skipped": return .secondaryLabelColor
        default:
            switch status {
            case "in_progress": return .systemYellow
            case "queued": return .secondaryLabelColor
            default: return .secondaryLabelColor
            }
        }
    }

    // MARK: - NSImage rendering

    /// Renders the status icon as a square `NSImage` suitable for the menu bar.
    /// - Parameter size: Width and height in points (default 18).
    func image(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let iconSize = size - 2
        let inset: CGFloat = 1
        let rect = NSRect(x: inset, y: inset, width: iconSize, height: iconSize)
        let bgPath = NSBezierPath(ovalIn: rect)
        color.withAlphaComponent(0.15).setFill()
        bgPath.fill()
        let fontSize = size * 0.55
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: icon, attributes: attrs)
        let strSize = attrStr.size()
        let drawX = (size - strSize.width) / 2
        let drawY = (size - strSize.height) / 2
        attrStr.draw(at: NSPoint(x: drawX, y: drawY))
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
// swiftlint:enable operator_usage_whitespace vertical_whitespace_opening_braces
