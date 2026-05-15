import AppKit

/// Renders the coloured status icon shown in the menu bar and popover rows.
struct StatusIcon {
    /// Current lifecycle status string.
    let status: String
    /// Final outcome string once the workflow/job finishes.
    let conclusion: String?

    /// Icon character for the current status/conclusion.
    var icon: String {
        switch conclusion {
        case "success":          return "\u{2713}"
        case "failure":          return "\u{2717}"
        case "cancelled":        return "\u{2298}"
        case "skipped":          return "\u{2298}"
        case "timed_out":        return "\u{2717}"
        case "action_required":  return "!"
        default:
            switch status {
            case "in_progress":  return "\u{25B6}"
            case "queued":       return "\u{00B7}"
            default:             return "\u{00B7}"
            }
        }
    }

    /// Foreground colour for the icon.
    var color: NSColor {
        switch conclusion {
        case "success":                  return .systemGreen
        case "failure", "timed_out":     return .systemRed
        case "action_required":          return .systemOrange
        case "cancelled", "skipped":     return .secondaryLabelColor
        default:
            switch status {
            case "in_progress":          return .systemYellow
            case "queued":               return .secondaryLabelColor
            default:                     return .secondaryLabelColor
            }
        }
    }

    // MARK: - NSImage rendering

    /// Renders the status icon as a square `NSImage` suitable for the menu bar.
    /// - Parameter size: Width and height in points (default 18).
    func image(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let bgPath = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2))
        color.withAlphaComponent(0.15).setFill()
        bgPath.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold),
            .foregroundColor: color
        ]
        let str = NSAttributedString(string: icon, attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(
            x: (size - strSize.width) / 2,
            y: (size - strSize.height) / 2
        ))
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
