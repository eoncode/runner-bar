import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel:
//   1. NSVisualEffectView background (hudWindow material, matches NSPopover look)
//   2. Rounded corners (cornerRadius = 10  ← NSPopover exact value, macOS Sequoia)
//   3. Arrow caret drawn at top, pointing up toward the status bar icon
//      arrowHeight=9, arrowWidth=20, tipRadius=3  ← NSPopover exact values
//      Arrow base is seamlessly merged into the rounded-rect path — no seam.
//
// Layout contract:
//   chrome IS the panel contentView. AppKit owns chrome.frame.
//   ❌ NEVER set chrome.frame manually from AppDelegate.
//   chrome.layout() is called by AppKit after every panel.setFrame().
//   It repositions fx (NSVisualEffectView) to contentRect ONLY.
//   The hosting view has autoresizingMask=[.width,.height] and is NOT touched
//   in layout() — AppKit fills it automatically as the panel resizes.
//   This lets SwiftUI render at full preferredContentSize so KVO fires correctly.
//   Panel height is driven by KVO → resizeAndRepositionPanel() → panel.setFrame().
//
//   contentRect = full bounds minus arrowHeight at top (macOS coords: y=0 at bottom):
//     NSRect(x:0, y:0, width:bounds.width, height:bounds.height - arrowHeight)
//
// arrowX: panel-local X of arrow tip centre.
//   Set by AppDelegate.resizeAndRepositionPanel() on every reposition.
//   Formula: buttonScreenFrame.midX - panelFrame.minX
//   (panelFrame is the CLAMPED frame after screen-edge correction)
//
// ❌ NEVER remove this file.
// ❌ NEVER add hosting-view frame overrides back to layout().
// ❌ NEVER set autoresizingMask=[] on the hosting view.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight:  CGFloat = 9
let arrowWidth:   CGFloat = 20
let cornerRadius: CGFloat = 10   // NSPopover exact value (macOS Sequoia)
let arrowTipRadius: CGFloat = 3  // NSPopover exact value

final class PanelChromeView: NSView {

    /// Panel-local X of arrow tip centre.
    /// Formula: buttonScreenFrame.midX - panel.frame.minX  (after screen-clamp)
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
        // Pin ONLY the visual effect background to contentRect.
        // ❌ NEVER override the hosting view frame here — the hosting view uses
        //    autoresizingMask=[.width,.height] so AppKit fills it automatically.
        //    Overriding it here breaks the chicken-and-egg: SwiftUI could never
        //    grow past the init height → preferredContentSize KVO never fired.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // ── Arrow + rounded-rect body merged into ONE seamless path ──────────
        //
        // We draw a single CGPath that is the rounded rectangle for the content
        // area PLUS the upward-pointing arrow caret at the top, seamlessly joined.
        // This eliminates any visible seam between the arrow base and the body.
        //
        // Coordinate system (macOS): y=0 at bottom, y=bounds.height at top.
        // The arrow tip is at bounds.height (very top). The base of the arrow
        // sits at baseY = bounds.height - arrowHeight = contentRect.maxY.
        // The rounded-rect occupies (0,0) → (bounds.width, baseY).
        //
        // Clamp arrowX so the caret stays within the rounded corners.
        let clampedX = max(arrowWidth / 2 + cornerRadius + arrowTipRadius,
                           min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius - arrowTipRadius))
        let baseY = bounds.height - arrowHeight  // = contentRect.maxY
        let tipY  = bounds.height                // top edge

        // Half-width of arrow at its base.
        let hw = arrowWidth / 2

        // Build the path starting at the bottom-left arc of the rounded rect
        // and working clockwise. At the top edge we insert the arrow caret
        // seamlessly between the two top-corner arcs.
        let r = cornerRadius
        let w = bounds.width

        let path = CGMutablePath()

        // Bottom-left corner
        path.move(to: CGPoint(x: r, y: 0))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                    startAngle: .pi * 1.5, endAngle: .pi, clockwise: true)
        // Left edge (bottom→top)
        path.addLine(to: CGPoint(x: 0, y: baseY - r))
        // Top-left corner
        path.addArc(center: CGPoint(x: r, y: baseY - r), radius: r,
                    startAngle: .pi, endAngle: .pi * 0.5, clockwise: true)

        // Top edge left segment → arrow left base
        path.addLine(to: CGPoint(x: clampedX - hw, y: baseY))

        // Arrow: left base → tip (rounded) → right base
        path.addArc(tangent1End: CGPoint(x: clampedX, y: tipY),
                    tangent2End: CGPoint(x: clampedX + hw, y: baseY),
                    radius: arrowTipRadius)

        // Arrow right base → top-right corner
        path.addLine(to: CGPoint(x: w - r, y: baseY))
        // Top-right corner
        path.addArc(center: CGPoint(x: w - r, y: baseY - r), radius: r,
                    startAngle: .pi * 0.5, endAngle: 0, clockwise: true)
        // Right edge (top→bottom)
        path.addLine(to: CGPoint(x: w, y: r))
        // Bottom-right corner
        path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                    startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
        // Bottom edge back to start
        path.addLine(to: CGPoint(x: r, y: 0))
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
