import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// Arrow shape: concave sides (iSapozhnik w/4 fractions) + 4pt rounded tip arc.
//
// The NSPopover arrow has:
//   - Slightly concave sides (curving inward) — iSapozhnik cubic Bezier formula.
//   - A small rounded tip (~4pt radius arc) — NOT a sharp point.
//
// Right side bezier: start=(cX+hw, baseY)  end=(cX+tipR, tipY)
//   cp1 = (cX + arrowWidth/4, baseY)  <- concave foot anchor
//   cp2 = (cX + tipR,         tipY)   <- arrives horizontally into arc (no kink)
//
// Tip arc: appendArc(center=(cX, tipY-tipR), radius=tipR, 0°→180°)
//   Sweeps the rounded apex counter-clockwise.
//
// Left side bezier (mirror): start=(cX-tipR, tipY)  end=(cX-hw, baseY)
//   cp1 = (cX - tipR,         tipY)   <- leaves horizontally from arc
//   cp2 = (cX - arrowWidth/4, baseY)  <- concave foot anchor
//
// ❌ NEVER remove the tip arc — causes sharp spike.
// ❌ NEVER widen CP offsets to hw/2 (=10pt) — causes half-circle blob.
// ❌ NEVER use straight lines only — flat arrow.
// ❌ NEVER use appendArc at BASE corners — visible base humps.
//
// KEY FACTS:
//
// 1. macOS coordinate system: y=0 is BOTTOM of view, y=bounds.height is TOP.
//    Arrow tip is at TOP. contentRect = (0, 0, w, h - arrowHeight).
//
// 2. fx (NSVisualEffectView) covers FULL bounds. Body-shape clipping via
//    CAShapeLayer mask on fx.layer. Rebuilt on every layout() + arrowX change.
//    ❌ NEVER set cornerRadius or masksToBounds on fx.layer directly.
//
// 3. arrowX: panel-local X of arrow tip centre.
//    Formula: button.window!.frame.midX - panel.frame.minX
//    ❌ NEVER compute from convertToScreen(button.frame).
//
// 4. Dynamic height: layout() re-pins ALL subviews on EVERY layout pass.
//    ❌ NEVER set hosting view frame only at init.
//    ❌ NEVER set autoresizingMask=[] on the hosting view.
//
// 5. NSBezierPath.cgPath is macOS 14+. Use .compatCGPath (extension below).
//
// ❌ NEVER remove this file. Regression is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowHeight:  CGFloat = 11   // matches NSPopover Sequoia
let arrowWidth:   CGFloat = 20   // matches NSPopover Sequoia
let cornerRadius: CGFloat = 10   // matches NSPopover body corner

// MARK: - NSBezierPath → CGPath (macOS 13 compatible)
// ❌ NEVER replace with .cgPath — requires macOS 14+.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
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
    /// ❌ NEVER compute from convertToScreen(button.frame).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    var arrowX: CGFloat = 240 {
        didSet { needsDisplay = true; updateFxMask() }
    }

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        // ❌ NEVER change .popover to .hudWindow or any other material.
        // .popover is the exact frosted-glass material used by native NSPopover.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // ❌ NEVER set layer?.backgroundColor = CGColor.clear (alpha 0.0).
        // alpha=0.0 disables CABackdropLayer — vibrancy collapses to flat grey.
        // Near-zero (0.001) keeps the backdrop sampler active.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        layer?.backgroundColor = CGColor(gray: 1, alpha: 0.001)
        addSubview(fx)
    }

    required init?(coder: NSCoder) { fatalError() }

    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        fx.frame = bounds
        updateFxMask()
        // Re-pin ALL non-fx subviews to contentRect on EVERY layout pass.
        // ❌ NEVER set hosting view frame only at init — dynamic height breaks.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    private func updateFxMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let maskLayer = CAShapeLayer()
        maskLayer.path = chromePath(in: bounds).compatCGPath
        fx.layer?.mask = maskLayer
    }

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
    //
    // Full chrome: rounded-rect body + upward arrow with concave sides + rounded tip.
    //
    // The tip uses appendArc(radius: tipR=4) at the apex.
    // Both bezier side curves arrive/depart horizontally at the arc tangent
    // points (cX ± tipR, tipY) so there is no kink where curve meets arc.
    //
    // ❌ NEVER remove the tip arc — causes sharp spike.
    // ❌ NEVER use appendArc at BASE corners — visible base humps.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w    = rect.width
        let h    = rect.height
        let r    = cornerRadius
        let hw   = arrowWidth / 2

        // tipR: radius of the rounded apex arc.
        // 4pt closely matches the native NSPopover rounded tip on Sonoma/Sequoia.
        // ❌ NEVER remove or set to 0 — causes sharp spike.
        // ❌ NEVER increase above hw (10pt) — arc would exceed arrow half-width.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        let tipR: CGFloat = 4

        // cpBase: iSapozhnik w/4 fraction anchors concave inward slope at foot.
        // w/4 = 5pt gives a softer, wider concave curve matching NSPopover.
        // ❌ NEVER change to hw/2 (=10pt) — half-circle blob.
        // ❌ NEVER change to w/6 (=3.33pt) — too narrow/pointy.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        let cpBase = arrowWidth / 4      // 5pt

        let cX    = max(hw + r, min(arrowX, w - hw - r))
        let baseY = h - arrowHeight
        let tipY  = h                    // outermost y of tip arc
        let tipCY = tipY - tipR          // centre y of tip arc circle

        let path = NSBezierPath()
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge → bottom-right corner
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        // Right edge → top-right corner
        path.line(to: NSPoint(x: w, y: baseY - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        // Top edge: right segment → arrow right foot
        path.line(to: NSPoint(x: cX + hw, y: baseY))

        // Arrow right side → right tangent of tip arc.
        // cp2 = (cX + tipR, tipY) so the bezier arrives perfectly horizontal,
        // tangent to the arc circle at its rightmost point. No kink.
        path.curve(to:            NSPoint(x: cX + tipR,   y: tipY),
                   controlPoint1: NSPoint(x: cX + cpBase,  y: baseY),
                   controlPoint2: NSPoint(x: cX + tipR,    y: tipY))

        // Tip arc: centre=(cX, tipCY), sweeps 0° → 180° (counter-clockwise).
        // 0° = right tangent, 180° = left tangent.
        // clockwise:false in NSBezierPath = counter-clockwise in screen coords
        // (AppKit flips the sense). This draws the rounded peak left-to-right.
        // ❌ NEVER remove this arc — it IS the rounded tip.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        path.appendArc(withCenter: NSPoint(x: cX,   y: tipCY),
                       radius: tipR,
                       startAngle: 0, endAngle: 180,
                       clockwise: false)

        // Arrow left side → left foot (exact mirror of right side).
        // Starts from (cX - tipR, tipY), the left tangent point of the arc.
        path.curve(to:            NSPoint(x: cX - hw,     y: baseY),
                   controlPoint1: NSPoint(x: cX - tipR,   y: tipY),
                   controlPoint2: NSPoint(x: cX - cpBase, y: baseY))

        // Top edge: left segment → top-left corner
        path.line(to: NSPoint(x: r, y: baseY))
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        // Left edge → bottom-left corner
        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
