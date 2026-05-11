import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// SOURCE: iSapozhnik/Popover arrow formula (MIT licensed).
// https://github.com/iSapozhnik/Popover/blob/master/Sources/Popover/PopoverWindowBackgroundView.swift
//
// The NSPopover arrow has CONCAVE sides (slightly curving inward) with a soft
// rounded tip. Achieved with two cubic Bezier curves using these fractions:
//
//   Right side: start=(cX+hw, baseY)  end=(cX, tipY)
//     cp1 = (cX + arrowWidth/6, baseY)    <- near foot, inward from right base
//     cp2 = (cX + arrowWidth/9, tipY)     <- near tip centre, at tip height
//
//   Left side (mirror): start=(cX, tipY)  end=(cX-hw, baseY)
//     cp1 = (cX - arrowWidth/9, tipY)     <- near tip centre, at tip height
//     cp2 = (cX - arrowWidth/6, baseY)    <- near foot, inward from left base
//
// With arrowWidth=20: w/6=3.33pt, w/9=2.22pt.
// Both sides curve INWARD (concave) and meet at a soft rounded point.
//
// ❌ NEVER widen the CP offsets (e.g. hw/2 = 10pt) — causes half-circle blob.
// ❌ NEVER use straight lines only — flat, no roundness.
// ❌ NEVER use appendArc(from:to:radius:) at base corners — visible base bumps.
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
    // Full chrome: rounded-rect body + upward concave-sided arrow.
    //
    // Arrow formula (iSapozhnik/Popover, MIT):
    //   Both sides use cubic Bezier with w/6 and w/9 offsets.
    //   This creates concave sides (curving inward) converging to a soft tip.
    //
    // ❌ NEVER change cp offsets to hw/2 (=10pt) — half-circle blob.
    // ❌ NEVER remove the curves — flat arrow.
    // ❌ NEVER add appendArc at base corners — base humps.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w  = rect.width
        let h  = rect.height
        let r  = cornerRadius
        let hw = arrowWidth / 2

        let cX    = max(hw + r, min(arrowX, w - hw - r))
        let baseY = h - arrowHeight
        let tipY  = h

        // iSapozhnik fractions: w/6 at base (inward from foot),
        //                       w/9 at tip  (inward from side)
        let cpBase = arrowWidth / 6   // 3.33pt
        let cpTip  = arrowWidth / 9   // 2.22pt

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

        // Top edge: right segment to arrow right foot
        path.line(to: NSPoint(x: cX + hw, y: baseY))

        // Arrow right side → tip (concave inward curve)
        // cp1 near the foot, on the base line — anchors curve at bottom
        // cp2 near tip centre, at tip height — guides into the soft rounded peak
        // ❌ NEVER set cp2.x to cX+hw/2 (=cX+10) — that bows outward (half-circle)
        path.curve(to:            NSPoint(x: cX,           y: tipY),
                   controlPoint1: NSPoint(x: cX + cpBase,  y: baseY),
                   controlPoint2: NSPoint(x: cX + cpTip,   y: tipY))

        // Arrow left side → left foot (exact mirror)
        path.curve(to:            NSPoint(x: cX - hw,      y: baseY),
                   controlPoint1: NSPoint(x: cX - cpTip,   y: tipY),
                   controlPoint2: NSPoint(x: cX - cpBase,  y: baseY))

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
