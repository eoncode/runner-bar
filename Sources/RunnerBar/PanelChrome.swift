import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
// Source research:
//   - Real NSPopover arrow (macOS Sequoia): straight sides with rounded corners.
//     Tip has ~3pt radius roundness. Base corners have ~2pt radius roundness.
//     Implemented via NSBezierPath.appendArc(from:to:radius:) at each corner
//     (= CGPath.addArc(tangent1End:tangent2End:radius:) in Core Graphics).
//   - arrowWidth = 20pt, arrowHeight = 11pt (calibrated to Sequoia).
//
// KEY FACTS (do not change without understanding all of them):
//
// 1. macOS coordinate system: y=0 is BOTTOM of view, y=bounds.height is TOP.
//    Arrow tip is at the TOP (high Y). Body is below the arrow.
//    contentRect = (0, 0, w, h - arrowHeight)  <- body lives here
//
// 2. fx (NSVisualEffectView) covers the FULL bounds — never clipped by its own
//    layer, never clips the arrow area. Body-shape clipping is done via a
//    CAShapeLayer mask on fx.layer, rebuilt on every layout() + arrowX change.
//    ❌ NEVER set cornerRadius or masksToBounds on fx.layer directly.
//
// 3. Arrow shape: straight sides + rounded corners via appendArc(from:to:radius:).
//    ❌ NEVER use explicit Bezier controlPoints on arrow sides — causes bowing.
//    ❌ NEVER use plain .line(to:) only — gives flat unrounded arrow.
//    ✅ Use appendArc(from:to:radius:) at each of the 3 arrow corners:
//         rightBase radius=arrowBaseRadius (2pt)
//         tip       radius=arrowTipRadius  (3pt)
//         leftBase  radius=arrowBaseRadius (2pt)
//    appendArc(from:to:radius:) is macOS 10.10+, works on macOS 13+.
//
// 4. arrowX: panel-local X of arrow tip centre.
//    Set by AppDelegate.resizeAndRepositionPanel() after screen-edge clamping.
//    Formula: button.window!.frame.midX - panel.frame.minX
//    ❌ NEVER compute from convertToScreen(button.frame).
//
// 5. Dynamic height: layout() re-pins ALL subviews (fx + hosting view) to their
//    correct frames on EVERY layout pass. Hosting view fills contentRect.
//    ❌ NEVER set hosting view frame only at init.
//    ❌ NEVER set autoresizingMask=[] on the hosting view.
//
// 6. macOS 13 compatibility:
//    NSBezierPath.cgPath is macOS 14+ ONLY.
//    ❌ NEVER use bezierPath.cgPath directly — use .compatCGPath extension.
//    The extension manually walks NSBezierPath elements and builds CGMutablePath.
//
// ❌ NEVER remove this file.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight:  CGFloat = 11   // matches NSPopover Sequoia
let arrowWidth:   CGFloat = 20   // matches NSPopover Sequoia
let cornerRadius: CGFloat = 10   // matches NSPopover body corner (macOS Sequoia)

/// Radius of the rounded tip of the arrow (matches NSPopover Sequoia ~3pt).
private let arrowTipRadius:  CGFloat = 3
/// Radius of the rounded base corners where arrow sides meet the body (NSPopover ~2pt).
private let arrowBaseRadius: CGFloat = 2

// MARK: - NSBezierPath → CGPath (macOS 13 compatible)
//
// NSBezierPath.cgPath requires macOS 14+. This extension is the standard
// pre-macOS-14 workaround: walk elements manually and build a CGMutablePath.
// ❌ NEVER replace with .cgPath directly — the project targets macOS 13.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
private extension NSBezierPath {
    var compatCGPath: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0 ..< elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:
                path.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
            case .lineTo:
                path.addLine(to: CGPoint(x: pts[0].x, y: pts[0].y))
            case .curveTo:
                path.addCurve(
                    to:       CGPoint(x: pts[2].x, y: pts[2].y),
                    control1: CGPoint(x: pts[0].x, y: pts[0].y),
                    control2: CGPoint(x: pts[1].x, y: pts[1].y)
                )
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(
                    to:       CGPoint(x: pts[2].x, y: pts[2].y),
                    control1: CGPoint(x: pts[0].x, y: pts[0].y),
                    control2: CGPoint(x: pts[1].x, y: pts[1].y)
                )
            case .quadraticCurveTo:
                path.addQuadCurve(
                    to:      CGPoint(x: pts[1].x, y: pts[1].y),
                    control: CGPoint(x: pts[0].x, y: pts[0].y)
                )
            @unknown default:
                break
            }
        }
        return path
    }
}

final class PanelChromeView: NSView {

    /// Panel-local X of arrow tip centre.
    /// Formula: button.window!.frame.midX - panel.frame.minX
    /// ❌ NEVER compute from convertToScreen(button.frame) — button.frame is button-local.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    var arrowX: CGFloat = 240 {
        didSet { needsDisplay = true; updateFxMask() }
    }

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        // ❌ NEVER set cornerRadius or masksToBounds here.
        // CAShapeLayer mask in updateFxMask() handles all clipping.
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        addSubview(fx)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rect below the arrow where content (hosting view) lives.
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        // fx covers FULL bounds so it never clips the arrow area.
        // ❌ NEVER set fx.frame = contentRect — it would clip the arrow region.
        fx.frame = bounds
        updateFxMask()
        // Re-pin hosting view (and any other non-fx subview) to contentRect
        // on EVERY layout pass so dynamic height works correctly.
        // ❌ NEVER set hosting view frame only at init — panel resize won't propagate.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression is major major major.
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    // MARK: - fx mask

    /// Rebuilds the CAShapeLayer mask on fx so only the body+arrow area is visible.
    /// Uses .compatCGPath (not .cgPath) for macOS 13 compatibility.
    /// ❌ NEVER use .cgPath here — it requires macOS 14+.
    private func updateFxMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let maskLayer = CAShapeLayer()
        maskLayer.path = chromePath(in: bounds).compatCGPath
        fx.layer?.mask = maskLayer
    }

    // MARK: - draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.01)
            : NSColor(white: 0.95, alpha: 0.01)
        ctx.setFillColor(fill.cgColor)
        chromePath(in: bounds).fill()
    }

    // MARK: - Chrome path

    /// Full chrome shape: rounded-rect body + upward arrow caret.
    ///
    /// Arrow corners use appendArc(from:to:radius:) which is the NSBezierPath
    /// equivalent of CGPath.addArc(tangent1End:tangent2End:radius:).
    /// Each corner is rounded tangentially — straight sides, rounded vertices.
    ///
    /// ❌ NEVER replace with explicit Bezier curves on sides — causes bowing.
    /// ❌ NEVER replace with plain .line(to:) — flat unrounded arrow.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w  = rect.width
        let h  = rect.height
        let r  = cornerRadius
        let hw = arrowWidth / 2   // 10pt half-width

        // Clamp arrow centre so caret never overlaps the rounded body corners.
        let cX = max(hw + r, min(arrowX, w - hw - r))

        let baseY = h - arrowHeight   // top of body / base of arrow
        let tipY  = h                 // very tip of arrow

        // The three arrow corner points (virtual, used as appendArc targets):
        let rightBase = NSPoint(x: cX + hw, y: baseY)
        let tip       = NSPoint(x: cX,      y: tipY)
        let leftBase  = NSPoint(x: cX - hw, y: baseY)

        let path = NSBezierPath()

        // Start bottom-left, go clockwise.
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge → bottom-right corner
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        // Right edge → top-right corner
        path.line(to: NSPoint(x: w, y: baseY - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        // Top-right body edge, then arrow:
        // appendArc(from:to:radius:) automatically lines to the tangent point
        // on the incoming segment, draws the arc, and leaves the current point
        // at the tangent point on the outgoing segment.
        //
        // Corner 1: right base — body-top meets right arrow side
        path.line(to: NSPoint(x: w - r, y: baseY))  // finish top-right arc exit
        path.appendArc(from: rightBase, to: tip,      radius: arrowBaseRadius)

        // Corner 2: tip — right side meets left side
        path.appendArc(from: tip,       to: leftBase, radius: arrowTipRadius)

        // Corner 3: left base — left arrow side meets body-top
        path.appendArc(from: leftBase,  to: NSPoint(x: r, y: baseY), radius: arrowBaseRadius)

        // Top-left body edge → top-left corner
        path.line(to: NSPoint(x: r, y: baseY))
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        // Left edge → bottom-left corner back to start
        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
