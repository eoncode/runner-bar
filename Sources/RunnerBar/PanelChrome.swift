import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// ARROW SHAPE — wide soft bump matching native NSPopover:
//   arrowWidth  = 26pt  (wide base)
//   arrowHeight = 8pt   (shallow/flat)
//   tipR        = 4pt   (small arc at apex for smooth round tip)
//
// Construction:
//   leftPoint  = (cX - hw, baseY)
//   tipPoint   = (cX, tipY)
//   rightPoint = (cX + hw, baseY)
//
//   Right bezier: rightPoint → tipArcStart
//     cp1 = (cX + hw*0.5, baseY)   ← gentle outward pull at base
//     cp2 = (cX + tipR,   tipY)    ← arrives just right of tip arc
//
//   Tip arc: small radius=tipR arc connecting right→left side smoothly
//
//   Left bezier: tipArcEnd → leftPoint
//     cp1 = (cX - tipR,   tipY)    ← departs just left of tip arc
//     cp2 = (cX - hw*0.5, baseY)   ← mirror of right
//
// ❌ NEVER set arrowHeight > 10 — too pointy.
// ❌ NEVER set arrowWidth < 22 — too narrow.
// ❌ NEVER set hw*0.5 → hw (blob) or 0 (straight lines).
// ❌ NEVER remove this file. Regression is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowHeight:  CGFloat = 8    // shallow = wide gentle bump like native NSPopover
let arrowWidth:   CGFloat = 26   // wide base matching native NSPopover
let arrowTipR:    CGFloat = 4    // small arc radius for smooth rounded tip
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
    // Wide shallow bump arrow with small tip arc — matches native NSPopover appearance.
    //
    // cp_base = hw * 0.5  — gentle outward pull at foot (soft wide curve, not straight)
    // tipR    = 4pt       — small arc at apex (smooth round tip, not sharp point)
    //
    // ❌ NEVER set arrowHeight > 10 (too pointy).
    // ❌ NEVER set arrowWidth < 22 (too narrow).
    // ❌ NEVER remove the tip arc — without it the two beziers meet in a sharp point.
    // ❌ NEVER use appendArc at BASE corners — visible base humps.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w   = rect.width
        let h   = rect.height
        let r   = cornerRadius
        let hw  = arrowWidth / 2          // 13pt
        let tr  = arrowTipR               // 4pt tip arc radius

        let cX    = max(hw + r, min(arrowX, w - hw - r))
        let baseY = h - arrowHeight        // y of arrow feet
        let tipY  = h                      // y of arrow apex centre

        // cp_base: gentle horizontal pull at foot — creates the soft wide curve.
        // ❌ NEVER set to 0 (straight lines) or hw (outward blob).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        let cp_base = hw * 0.5             // 6.5pt

        // Tip arc endpoints (arc centred at (cX, tipY - tr))
        let tipArcCentre = NSPoint(x: cX,       y: tipY - tr)
        let tipArcRight  = NSPoint(x: cX + tr,  y: tipY - tr) // 0° entry from right bezier
        let tipArcLeft   = NSPoint(x: cX - tr,  y: tipY - tr) // 180° exit to left bezier

        let leftPoint  = NSPoint(x: cX - hw, y: baseY)
        let rightPoint = NSPoint(x: cX + hw, y: baseY)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge → BR corner
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        // Right edge → TR corner
        path.line(to: NSPoint(x: w, y: baseY - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        // Top-right → right arrow foot
        path.line(to: rightPoint)

        // Right bezier: foot → tip arc entry
        // cp1 = (cX + cp_base, baseY) — gentle pull upward from base
        // cp2 = (cX + tr,      tipY)  — arrives at arc entry tangentially
        path.curve(to:            tipArcRight,
                   controlPoint1: NSPoint(x: cX + cp_base, y: baseY),
                   controlPoint2: NSPoint(x: cX + tr,      y: tipY))

        // Tip arc: right → left, clockwise (180° sweep, startAngle=0 endAngle=180)
        path.appendArc(withCenter: tipArcCentre,
                       radius: tr, startAngle: 0, endAngle: 180)

        // Left bezier: tip arc exit → left foot (mirror of right)
        path.curve(to:            leftPoint,
                   controlPoint1: NSPoint(x: cX - tr,      y: tipY),
                   controlPoint2: NSPoint(x: cX - cp_base, y: baseY))

        // Top-left → TL corner
        path.line(to: NSPoint(x: r, y: baseY))
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        // Left edge → BL corner
        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
