import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly.
// Pattern adapted from iSapozhnik/Popover (MIT):
//   https://github.com/iSapozhnik/Popover/blob/master/Sources/Popover/PopoverWindowBackgroundView.swift
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
// 3. Arrow is drawn via chromePath() using NSBezierPath with cubic Bezier curves
//    (curve(to:controlPoint1:controlPoint2:)) for smooth NSPopover-style sides.
//    overlapY = baseY - 1: arrow base extends 1pt INTO body for seamless join.
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
//    ❌ NEVER use bezierPath.cgPath directly — use bezierPathCGPath() extension below.
//    The extension manually walks the NSBezierPath elements and builds a CGMutablePath.
//
// ❌ NEVER remove this file.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight:  CGFloat = 9    // matches NSPopover (Sequoia)
let arrowWidth:   CGFloat = 20   // matches NSPopover standard
let cornerRadius: CGFloat = 10   // matches NSPopover exact value (macOS Sequoia)

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
            case .cubicCurveTo:  // same as curveTo in newer SDK naming
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

    /// Rebuilds the CAShapeLayer mask on fx so only the body+arrow area is
    /// visible. This replaces the broken cornerRadius/masksToBounds approach
    /// that clipped the arrow base and left a visible cutout.
    ///
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
        // Near-transparent fill: NSVisualEffectView shows through, but the path
        // still fills the gap between the arrow and body at the join.
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.01)
            : NSColor(white: 0.95, alpha: 0.01)
        ctx.setFillColor(fill.cgColor)
        chromePath(in: bounds).fill()
    }

    // MARK: - Shared chrome path

    /// Single NSBezierPath for the full chrome: rounded-rect body + upward
    /// arrow caret with cubic Bezier sides (exact iSapozhnik/NSPopover pattern).
    /// Used for both draw() fill and the CAShapeLayer fx mask.
    ///
    /// Coordinate system: y=0 at BOTTOM, y=bounds.height at TOP.
    ///   tipY  = bounds.height  (arrow tip, very top of view)
    ///   baseY = bounds.height - arrowHeight  (arrow base = body top)
    ///   overlapY = baseY - 1  (1pt inside body for seamless fill join)
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w  = rect.width
        let h  = rect.height
        let r  = cornerRadius
        let hw = arrowWidth / 2

        // Clamp arrow centre so caret never overlaps the rounded corners.
        let cX = max(hw + r, min(arrowX, w - hw - r))

        let baseY    = h - arrowHeight
        let tipY     = h
        let overlapY = baseY - 1   // 1pt into body — eliminates gap at join

        // Cubic Bezier control-point offset.
        // Value 3 gives the slightly-concave sides that match NSPopover's caret.
        let cp: CGFloat = 3

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

        // Top edge: right segment to arrow right base
        path.line(to: NSPoint(x: cX + hw, y: baseY))

        // Arrow right side → tip (cubic Bezier, smooth NSPopover caret shape)
        path.curve(to: NSPoint(x: cX, y: tipY),
                   controlPoint1: NSPoint(x: cX + hw,     y: overlapY + cp),
                   controlPoint2: NSPoint(x: cX + hw / 2, y: tipY))

        // Arrow left side → left base (cubic Bezier, mirrored)
        path.curve(to: NSPoint(x: cX - hw, y: baseY),
                   controlPoint1: NSPoint(x: cX - hw / 2, y: tipY),
                   controlPoint2: NSPoint(x: cX - hw,     y: overlapY + cp))

        // Top edge: left segment → top-left corner
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
