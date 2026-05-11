import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
//
// ARROW SHAPE — DEFINITIVE (reverse-engineered from native NSPopover + SFBPopovers reference):
//
// Native NSPopover uses STRAIGHT LINES to the tip — NO bezier curves, NO tip radius.
// Reference: github.com/sbooth/SFBPopovers — appendArrowToPath uses lineToPoint only.
//
//   right foot (cX+hw, baseY)
//         |
//         |  straight line
//         v
//       tip (cX, tipY)        <- sharp point, no arc
//         |
//         |  straight line
//         v
//   left foot (cX-hw, baseY)
//
// Dimensions matching native NSPopover (Sonoma / Sequoia):
//   arrowWidth  = 20pt  (half = 10pt each side)
//   arrowHeight = 16pt  (NOT 11 — native is taller/sharper than earlier guess)
//   cornerRadius = 10pt (body)
//
// ❌ NEVER add bezier curves or tipRadius to the arrow sides. Straight lines only.
// ❌ NEVER set arrowHeight = 11 or lower — arrow becomes a flat stub.
// ❌ NEVER use appendArc at base corners — visible humps at feet.
// ❌ NEVER remove this file. Regression is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowHeight:  CGFloat = 16   // native NSPopover (Sonoma/Sequoia) — straight-sided arrow
let arrowWidth:   CGFloat = 20   // native NSPopover (Sonoma/Sequoia)
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
    // Rounded-rect body + upward arrow with STRAIGHT SIDES and SHARP TIP.
    //
    // This exactly matches native NSPopover arrow geometry.
    // Reference: SFBPopovers appendArrowToPath — lineToPoint only, no curves.
    //
    // Path order (clockwise from bottom-left, macOS coords y-up):
    //   BL arc → bottom edge → BR arc → right edge → TR arc
    //   → top-right segment → right arrow foot → TIP → left arrow foot
    //   → top-left segment → TL arc → left edge → close
    //
    // ❌ NEVER add curves to the arrow sides — straight lines only.
    // ❌ NEVER add tipRadius — tip must be a sharp point.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w  = rect.width
        let h  = rect.height
        let r  = cornerRadius
        let hw = arrowWidth / 2        // 10pt half-width

        let cX    = max(hw + r, min(arrowX, w - hw - r))
        let baseY = h - arrowHeight    // y of arrow feet (top of body)
        let tipY  = h                  // y of arrow tip

        let path = NSBezierPath()

        // Start: bottom-left, past the corner arc
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge → BR corner
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        // Right edge → TR corner
        path.line(to: NSPoint(x: w, y: baseY - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        // Top edge: right of arrow → right foot
        path.line(to: NSPoint(x: cX + hw, y: baseY))

        // Arrow: right foot → tip (STRAIGHT LINE — matches native NSPopover)
        // ❌ NEVER replace with a curve. Straight line only.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        path.line(to: NSPoint(x: cX, y: tipY))

        // Arrow: tip → left foot (STRAIGHT LINE)
        // ❌ NEVER replace with a curve. Straight line only.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        path.line(to: NSPoint(x: cX - hw, y: baseY))

        // Top edge: left of arrow → TL corner
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
