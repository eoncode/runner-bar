import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// Arrow shape: two cubic bezier curves — iSapozhnik exact formula.
// NO separate tip arc. Both beziers meet at the tip point (toPoint).
//
// The NSPopover arrow (iSapozhnik reverse-engineered formula):
//   leftPoint  = (cX - hw, baseY)        — left foot
//   toPoint    = (cX, baseY + arrowH)    — tip apex
//   rightPoint = (cX + hw, baseY)        — right foot
//
//   Left bezier:  leftPoint → toPoint
//     cp1 = (cX - w/6, baseY)            — concave foot anchor
//     cp2 = (cX - w/5, baseY+arrowH)    — near-tip anchor
//
//   Right bezier: toPoint → rightPoint
//     cp1 = (cX + w/5, baseY+arrowH)    — near-tip anchor (mirror)
//     cp2 = (cX + w/6, baseY)           — concave foot anchor
//
// With arrowWidth=30: cp_foot=w/6=5pt, cp_tip=w/5=6pt.
// Tip CPs are 12pt apart at tipY => soft rounded arch matching NSPopover Sequoia.
//
// ❌ NEVER change cp_tip back to w/9 (3.33pt) — tip CPs 6.67pt apart => pointy apex.
// ❌ NEVER change cp_tip to hw (15pt) — too wide, outward blob.
// ❌ NEVER add a separate tip arc — the two-bezier meeting at toPoint IS the rounded tip.
// ❌ NEVER use straight lines — flat / no concavity.
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

let arrowHeight:  CGFloat = 9    // shallower = flatter arch, matches original NSPopover
let arrowWidth:   CGFloat = 30   // wider base, matches original NSPopover
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
    // iSapozhnik two-bezier arrow with adjusted cp_tip fraction.
    //
    //   Left bezier:  leftPoint → toPoint,  cp1=(cX-w/6, baseY), cp2=(cX-w/5, tipY)
    //   Right bezier: toPoint → rightPoint, cp1=(cX+w/5, tipY),  cp2=(cX+w/6, baseY)
    //
    // cp_foot = w/6 = 5pt  (concave foot anchor)
    // cp_tip  = w/5 = 6pt  (near-tip anchor, 12pt spread => soft rounded arch)
    //
    // ❌ NEVER set cp_tip = w/9 (pointy) or hw (blob).
    // ❌ NEVER add a tip arc.
    // ❌ NEVER use appendArc at BASE corners.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w      = rect.width
        let h      = rect.height
        let r      = cornerRadius
        let hw     = arrowWidth / 2

        let cX     = max(hw + r, min(arrowX, w - hw - r))
        let baseY  = h - arrowHeight
        let tipY   = h

        let cp_foot = arrowWidth / 6   // 5pt  — concave foot anchor
        let cp_tip  = arrowWidth / 5   // 6pt  — near-tip anchor, 12pt spread => soft arch
        // ❌ NEVER change cp_tip to w/9 (pointy) or hw (15pt, blob).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.

        let leftPoint  = NSPoint(x: cX - hw, y: baseY)
        let toPoint    = NSPoint(x: cX,      y: tipY)
        let rightPoint = NSPoint(x: cX + hw, y: baseY)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: r, y: 0))

        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        path.line(to: NSPoint(x: w, y: baseY - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        path.line(to: rightPoint)

        // Arrow right side: rightPoint → toPoint
        // cp1 at foot level pulls the curve slightly inward (concave)
        // cp2 spread wide at tip height => broad soft arch
        path.curve(to:            toPoint,
                   controlPoint1: NSPoint(x: cX + cp_foot, y: baseY),
                   controlPoint2: NSPoint(x: cX + cp_tip,  y: tipY))

        // Arrow left side: toPoint → leftPoint (exact mirror)
        path.curve(to:            leftPoint,
                   controlPoint1: NSPoint(x: cX - cp_tip,  y: tipY),
                   controlPoint2: NSPoint(x: cX - cp_foot, y: baseY))

        path.line(to: NSPoint(x: r, y: baseY))
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
