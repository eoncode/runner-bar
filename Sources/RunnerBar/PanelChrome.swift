import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// SOURCE: iSapozhnik/Popover arrow formula (MIT licensed), adjusted tip fraction.
// https://github.com/iSapozhnik/Popover/blob/master/Sources/Popover/PopoverWindowBackgroundView.swift
//
// The NSPopover arrow has CONCAVE sides (slightly curving inward) with a WIDE,
// BROADLY-ARCHED tip — NOT a sharp point.
//
// Two cubic Bezier curves (right side and left side mirror):
//
//   Right side: start=(cX+hw, baseY)  end=(cX, tipY)
//     cp1 = (cX + arrowWidth/6, baseY)    <- near foot, slightly inward from base
//     cp2 = (cX + arrowWidth/3, tipY)     <- WIDE offset at tip height
//
//   Left side: start=(cX, tipY)  end=(cX-hw, baseY)
//     cp1 = (cX - arrowWidth/3, tipY)     <- WIDE offset at tip height (mirror)
//     cp2 = (cX - arrowWidth/6, baseY)    <- near foot, slightly inward from base
//
// With arrowWidth=20:
//   cpBase = w/6 = 3.33pt  (inward at base)
//   cpTip  = w/3 = 6.67pt  (spread at tip — 13.3pt apart => wide arch)
//
// The wide spread of cp2 points at tipY makes the two curves meet in a broad,
// gently rounded arch matching NSPopover Sequoia, NOT a sharp point.
//
// ❌ NEVER set cpTip = w/9 (2.22pt) — tip CPs only 4.4pt apart => sharp point.
// ❌ NEVER set cpTip = hw (10pt) — same as the base foot => outward bow, half-circle.
// ❌ NEVER use straight .line(to:) only — flat arrow.
// ❌ NEVER use appendArc(from:to:radius:) at base corners — visible base bumps.
//
// KEY FACTS:
//
// 1. macOS coordinate system: y=0 is BOTTOM, y=bounds.height is TOP.
//    Arrow tip at TOP. contentRect = (0, 0, w, h - arrowHeight).
//
// 2. fx (NSVisualEffectView) covers FULL bounds. Clipping via CAShapeLayer mask.
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
//    ❌ NEVER use .cgPath directly.
//
// ❌ NEVER remove this file. Regression is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowHeight:  CGFloat = 11   // matches NSPopover Sequoia
let arrowWidth:   CGFloat = 20   // matches NSPopover Sequoia
let cornerRadius: CGFloat = 10   // matches NSPopover body corner

// MARK: - NSBezierPath → CGPath (macOS 13 compatible)
// NSBezierPath.cgPath requires macOS 14+. Walk elements manually instead.
// ❌ NEVER replace with .cgPath — crashes on macOS 13.
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
    /// ❌ NEVER compute from convertToScreen(button.frame) — button.frame is button-local.
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
    // Full chrome: rounded-rect body + upward arrow.
    //
    // Arrow: two cubic Bezier curves with w/6 (base) and w/3 (tip) offsets.
    //   cpBase = w/6 = 3.33pt  cp1, near foot on base line
    //   cpTip  = w/3 = 6.67pt  cp2, spread wide at tip height => broad arch
    //
    // ❌ NEVER change cpTip to w/9 — too close, makes sharp point.
    // ❌ NEVER change cpTip to hw (10pt) — too wide, makes half-circle blob.
    // ❌ NEVER remove the curves — flat arrow.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w  = rect.width
        let h  = rect.height
        let r  = cornerRadius
        let hw = arrowWidth / 2

        let cX    = max(hw + r, min(arrowX, w - hw - r))
        let baseY = h - arrowHeight
        let tipY  = h

        let cpBase = arrowWidth / 6   // 3.33pt — cp1, anchors near foot on base line
        let cpTip  = arrowWidth / 3   // 6.67pt — cp2, wide spread at tip => broad arch
        // ❌ NEVER change cpTip to w/9 (sharp) or hw (half-circle)

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

        // Top-right body segment → arrow right foot
        path.line(to: NSPoint(x: cX + hw, y: baseY))

        // Arrow right side → tip
        // cp1=(cX+cpBase, baseY): anchors near foot, slightly inward
        // cp2=(cX+cpTip,  tipY):  wide offset at top — broad arch, not sharp
        path.curve(to:            NSPoint(x: cX,          y: tipY),
                   controlPoint1: NSPoint(x: cX + cpBase, y: baseY),
                   controlPoint2: NSPoint(x: cX + cpTip,  y: tipY))

        // Arrow left side → left foot (exact mirror)
        path.curve(to:            NSPoint(x: cX - hw,     y: baseY),
                   controlPoint1: NSPoint(x: cX - cpTip,  y: tipY),
                   controlPoint2: NSPoint(x: cX - cpBase, y: baseY))

        // Top-left body segment → top-left corner
        path.line(to: NSPoint(x: r, y: baseY))
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        // Left edge → bottom-left corner → close
        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
