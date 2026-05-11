import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel:
//   1. NSVisualEffectView background (hudWindow material, matches NSPopover look)
//   2. Rounded corners (cornerRadius = 12)
//   3. Arrow caret drawn at top, pointing up toward the status bar icon
//
// Layout contract:
//   chrome IS the panel contentView. AppKit owns chrome.frame.
//   ❌ NEVER set chrome.frame manually from AppDelegate.
//   chrome.layout() is called by AppKit after every panel.setFrame().
//   It repositions fx (NSVisualEffectView) to contentRect.
//   It does NOT clamp the hosting view — let SwiftUI render at full height
//   so preferredContentSize KVO fires correctly. Panel height is driven
//   by KVO → resizeAndRepositionPanel() → panel.setFrame(), not by clamping here.
//
//   contentRect = full bounds minus arrowHeight at top (macOS coords: y=0 at bottom):
//     NSRect(x:0, y:0, width:bounds.width, height:bounds.height - arrowHeight)
//
// arrowX: panel-local X of arrow tip centre.
//   Set by AppDelegate.resizeAndRepositionPanel() on every reposition.
//   Formula: buttonScreenFrame.midX - panelFrame.minX
//
// ❌ NEVER remove this file.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight: CGFloat = 8
let arrowWidth:  CGFloat = 16
let cornerRadius: CGFloat = 12

final class PanelChromeView: NSView {

    /// Panel-local X of arrow tip centre.
    /// Formula: buttonScreenFrame.midX - panel.frame.minX
    var arrowX: CGFloat = 240 { didSet { needsDisplay = true } }

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
        layer?.backgroundColor = CGColor.clear
        addSubview(fx)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rect below the arrow where content (fx + hosting view) lives.
    /// macOS coordinate system: y=0 is at bottom of view.
    /// Arrow is at TOP of view (high Y values), content is below it (low Y values).
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        // Pin the visual effect background to contentRect.
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        // Hosting view (non-fx subviews) fills contentRect.
        // We do NOT clamp its size here — SwiftUI must render at its natural
        // preferredContentSize so KVO fires. The panel height is driven by KVO.
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Arrow caret — upward pointing rounded triangle.
        // In macOS coords: tip is at HIGH y (top of view), base is at lower y.
        let clampedX = max(arrowWidth / 2 + cornerRadius,
                           min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius))
        let tipY  = bounds.height          // top edge of view
        let baseY = bounds.height - arrowHeight  // = contentRect.maxY

        let path = CGMutablePath()
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
