import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel:
//   1. NSVisualEffectView background (hudWindow material, matches NSPopover look)
//   2. Rounded corners (cornerRadius = 12, matching macOS popover)
//   3. Arrow caret drawn at the top, pointing upward toward the status bar icon
//
// Layout contract:
//   chrome is the panel contentView. AppKit owns chrome.frame (= panel.contentRect).
//   ❌ NEVER set chrome.frame manually from AppDelegate — AppKit overrides it.
//   chrome.layout() is called by AppKit after every panel.setFrame().
//   It pins fx (NSVisualEffectView) and the hosting view to contentRect.
//
//   contentRect = full bounds minus arrowHeight at top:
//     NSRect(x:0, y:0, width:bounds.width, height:bounds.height - arrowHeight)
//
//   The hosting view must have autoresizingMask = [] to prevent it from
//   auto-expanding to preferredContentSize and blowing past contentRect.
//
// arrowX: panel-local X of arrow tip centre.
//   Updated by AppDelegate.resizeAndRepositionPanel() on every reposition.
//
// ❌ NEVER remove this file — it provides background + rounding + arrow.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

let arrowHeight: CGFloat = 8
let arrowWidth:  CGFloat = 16
let cornerRadius: CGFloat = 12

final class PanelChromeView: NSView {

    /// Panel-local X coordinate of the arrow tip centre.
    /// Set by AppDelegate to buttonMidX - panelOriginX.
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.autoresizingMask = []
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Clear background — visual effect view provides the fill.
        // Arrow is drawn via draw(_:) above the visual effect rect.
        layer?.backgroundColor = CGColor.clear
        addSubview(fx)
    }

    required init?(coder: NSCoder) { fatalError() }

    // The rect below the arrow where content (fx + hosting view) lives.
    // AppKit calls layout() after every setFrame() — this is always fresh.
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        // Pin ALL non-fx subviews (hosting view) to contentRect.
        // autoresizingMask=[] on the hosting view ensures it does not
        // auto-expand; layout() re-pins it here on every AppKit layout pass.
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Arrow caret — upward pointing rounded triangle above the content rect.
        // tip Y = top of bounds. base Y = contentRect.maxY.
        let clampedX = max(arrowWidth / 2 + cornerRadius,
                           min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius))
        let tipY  = bounds.height
        let baseY = bounds.height - arrowHeight

        let path = CGMutablePath()
        // Rounded tip using addArc(tangent:)
        path.move(to: CGPoint(x: clampedX - arrowWidth / 2, y: baseY))
        path.addArc(tangent1End: CGPoint(x: clampedX, y: tipY),
                    tangent2End: CGPoint(x: clampedX + arrowWidth / 2, y: baseY),
                    radius: 2.5)
        path.addLine(to: CGPoint(x: clampedX + arrowWidth / 2, y: baseY))
        path.closeSubpath()

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.97)
            : NSColor(white: 0.95, alpha: 0.97)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
}
