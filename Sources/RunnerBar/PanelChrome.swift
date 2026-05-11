import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel:
//   1. NSVisualEffectView background (hudWindow material, matches NSPopover look)
//   2. Rounded corners (cornerRadius = 10  ← NSPopover exact value, macOS Sequoia)
//   3. Arrow caret drawn at top, pointing up toward the status bar icon
//      arrowHeight=9, arrowWidth=20, tipRadius=3  ← NSPopover exact values
//
// Drawing approach: two CGPaths filled with the same colour in draw():
//   • Path 1: CGPath(roundedRect:) for the body (bullet-proof corners)
//   • Path 2: arrow triangle with addArc for the rounded tip
// Filling both in one draw() call makes them appear seamless.
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
//   Formula: buttonScreenFrame.midX - panelFrame.minX  (after screen-clamp)
//
// ❌ NEVER remove this file.
// ❌ NEVER add hosting-view frame overrides back to layout().
// ❌ NEVER set autoresizingMask=[] on the hosting view.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight:    CGFloat = 9
let arrowWidth:     CGFloat = 20
let cornerRadius:   CGFloat = 10   // NSPopover exact value (macOS Sequoia)
let arrowTipRadius: CGFloat = 3    // NSPopover exact value

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

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.97)
            : NSColor(white: 0.95, alpha: 0.97)
        ctx.setFillColor(fill.cgColor)

        // ── Path 1: rounded-rect body ──────────────────────────────────
        // CGPath(roundedRect:) is bulletproof — no manual arc winding needed.
        let bodyRect = CGRect(x: 0, y: 0,
                              width: bounds.width, height: bounds.height - arrowHeight)
        let bodyPath = CGPath(roundedRect: bodyRect,
                              cornerWidth: cornerRadius,
                              cornerHeight: cornerRadius,
                              transform: nil)
        ctx.addPath(bodyPath)
        ctx.fillPath()

        // ── Path 2: arrow caret ────────────────────────────────────────
        // Upward-pointing triangle with a rounded tip via addArc(tangent:).
        // baseY = top of body = bottom of arrow zone.
        // tipY  = bounds.height (very top of view in macOS coords).
        //
        // Clamp so the caret never bleeds into the rounded body corners.
        let hw = arrowWidth / 2
        let clampedX = max(hw + cornerRadius,
                           min(arrowX, bounds.width - hw - cornerRadius))
        let baseY = bounds.height - arrowHeight
        let tipY  = bounds.height

        // The arrow fills the gap between the two corner caps of the body at
        // that X position, so it appears flush against the body top edge.
        // A small overlap of 1pt covers any sub-pixel gap between body & arrow.
        let overlapY = baseY + 1

        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: clampedX - hw, y: overlapY))
        arrowPath.addArc(tangent1End: CGPoint(x: clampedX,       y: tipY),
                         tangent2End: CGPoint(x: clampedX + hw,  y: overlapY),
                         radius: arrowTipRadius)
        arrowPath.addLine(to: CGPoint(x: clampedX + hw, y: overlapY))
        arrowPath.closeSubpath()

        ctx.addPath(arrowPath)
        ctx.fillPath()
    }
}
