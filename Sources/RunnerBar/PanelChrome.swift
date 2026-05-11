import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel:
//   1. NSVisualEffectView background (HUD material, matches NSPopover)
//   2. Rounded corners (cornerRadius = 12, matching macOS popover)
//   3. Arrow caret drawn at the top, pointing upward toward the status bar icon
//
// Usage:
//   let chrome = PanelChromeView(arrowX: x)
//   panel.contentView = chrome
//   chrome.addSubview(hostingController.view) — pinned to chrome.contentRect
//
// arrowX: the screen-space midX of the status button, converted to panel-local coords.
// Call chrome.arrowX = newX whenever the panel repositions.
//
// ❌ NEVER remove this file — it provides background + rounding + arrow.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowHeight: CGFloat = 8
let arrowWidth:  CGFloat = 16
let cornerRadius: CGFloat = 12

final class PanelChromeView: NSView {

    /// Panel-local X coordinate of the arrow tip centre.
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(fx)
    }

    required init?(coder: NSCoder) { fatalError() }

    // The rect below the arrow where content lives.
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
    }

    override func layout() {
        super.layout()
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        // Propagate to hosting view if already added.
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Arrow caret path — upward pointing triangle sitting above the rounded rect body.
        // tip Y = top of bounds, base Y = contentRect.maxY = bounds.height - arrowHeight.
        let tipX = max(arrowWidth / 2 + cornerRadius, min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius))
        let tipY = bounds.height          // top edge
        let baseY = bounds.height - arrowHeight

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: tipX, y: tipY))
        arrow.addLine(to: CGPoint(x: tipX - arrowWidth / 2, y: baseY))
        arrow.addLine(to: CGPoint(x: tipX + arrowWidth / 2, y: baseY))
        arrow.closeSubpath()

        // Determine fill color to match the visual effect view.
        // In dark mode: ~#2b2b2b, light mode: ~#f5f5f5. We read from the appearance.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.97)
            : NSColor(white: 0.95, alpha: 0.97)

        ctx.setFillColor(fillColor.cgColor)
        ctx.addPath(arrow)
        ctx.fillPath()
    }
}
