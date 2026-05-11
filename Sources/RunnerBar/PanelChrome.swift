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
//     cp2 = (cX - w/9, baseY+arrowH)    — near-tip anchor (creates rounded look)
//
//   Right bezier: toPoint → rightPoint
//     cp1 = (cX + w/9, baseY+arrowH)    — near-tip anchor (mirror)
//     cp2 = (cX + w/6, baseY)           — concave foot anchor
//
// ❌ NEVER add a separate tip arc — the two-bezier meeting at toPoint IS the
//    rounded tip. An arc makes it look wrong.
// ❌ NEVER use straight lines — flat / no concavity.
// ❌ NEVER use appendArc at BASE corners — visible base humps.
// ❌ NEVER change w/6 or w/9 — changes the concave profile entirely.
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

let arrowHeight:  CGFloat = 9    // shallower to match original NSPopover look
let arrowWidth:   CGFloat = 30   // wider to match original NSPopover look
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
    // iSapozhnik exact two-bezier arrow formula.
    // Source: github.com/iSapozhnik/Popover — PopoverWindowBackgroundView.swift
    //
    //   Left bezier:  leftPoint → toPoint,  cp1=(cX-w/6, baseY), cp2=(cX-w/9, tipY)
    //   Right bezier: toPoint → rightPoint, cp1=(cX+w/9, tipY),  cp2=(cX+w/6, baseY)
    //
    // The two beziers converge at toPoint (the tip). The near-tip anchors (w/9)
    // create the naturally rounded apex — no arc needed.
    //
    // ❌ NEVER add a tip arc.
    // ❌ NEVER change the w/6 or w/9 fractions.
    // ❌ NEVER use appendArc at BASE corners — visible base humps.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w      = rect.width
        let h      = rect.height
        let r      = cornerRadius
        let hw     = arrowWidth / 2

        // Arrow centre X clamped so the arrow never clips the body corners.
        let cX     = max(hw + r, min(arrowX, w - hw - r))
        let baseY  = h - arrowHeight   // y of arrow feet (top of body)
        let tipY   = h                 // y of arrow apex

        // iSapozhnik control point fractions (DO NOT CHANGE):
        //   w/6 = 5pt   — concave foot anchor
        //   w/9 = 3.33pt — near-tip anchor (produces the rounded apex)
        // ❌ NEVER change these fractions.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        let cp_foot = arrowWidth / 6   // 5pt — foot-side control offset
        let cp_tip  = arrowWidth / 9   // 3.33pt — tip-side control offset

        let leftPoint  = NSPoint(x: cX - hw, y: baseY)
        let toPoint    = NSPoint(x: cX,      y: tipY)
        let rightPoint = NSPoint(x: cX + hw, y: baseY)

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

        // Top edge: right segment → right arrow foot
        path.line(to: rightPoint)

        // Arrow right side: rightPoint → toPoint
        // cp1=(cX+w/6, baseY)  cp2=(cX+w/9, tipY)
        path.curve(to:            toPoint,
                   controlPoint1: NSPoint(x: cX + cp_foot, y: baseY),
                   controlPoint2: NSPoint(x: cX + cp_tip,  y: tipY))

        // Arrow left side: toPoint → leftPoint
        // cp1=(cX-w/9, tipY)   cp2=(cX-w/6, baseY)
        path.curve(to:            leftPoint,
                   controlPoint1: NSPoint(x: cX - cp_tip,  y: tipY),
                   controlPoint2: NSPoint(x: cX - cp_foot, y: baseY))

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
