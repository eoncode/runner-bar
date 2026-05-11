import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel.
// Pattern adapted from iSapozhnik/Popover (MIT):
//   https://github.com/iSapozhnik/Popover/blob/master/Sources/Popover/PopoverWindowBackgroundView.swift
//
// KEY FACTS (do not change without understanding all of them):
//
// 1. macOS coordinate system: y=0 is BOTTOM of view, y=bounds.height is TOP.
//    Arrow tip is at the TOP (high Y). Body is below the arrow.
//    contentRect = (0, 0, w, h - arrowHeight)  <- body lives here
//
// 2. fx (NSVisualEffectView) covers the FULL bounds so it is never clipped
//    by its own layer and does not cut into the arrow area.
//    Body-shape clipping is applied via a CAShapeLayer mask on fx.layer
//    that is rebuilt on every layout() call.
//
// 3. Arrow is drawn in draw() using NSBezierPath with cubic Bezier curves
//    (curve(to:controlPoint1:controlPoint2:)) for smooth NSPopover-style sides.
//    overlapY = baseY - 1: the arrow base extends 1pt INTO the body so the
//    fill is seamless with no gap or cutout at the join.
//
// 4. arrowX: panel-local X of arrow tip centre.
//    Set by AppDelegate.resizeAndRepositionPanel() AFTER screen-edge clamping.
//    Formula: buttonScreenFrame.midX - clampedPanelOriginX
//
// ❌ NEVER remove this file.
// ❌ NEVER add hosting-view frame overrides back to layout().
// ❌ NEVER set autoresizingMask=[] on the hosting view.
// ❌ NEVER add cornerRadius / masksToBounds directly to fx.layer —
//    the CAShapeLayer mask handles clipping instead.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight:    CGFloat = 9
let arrowWidth:     CGFloat = 20
let cornerRadius:   CGFloat = 10   // NSPopover exact value (macOS Sequoia)

final class PanelChromeView: NSView {

    /// Panel-local X of arrow tip centre.
    var arrowX: CGFloat = 240 { didSet { needsDisplay = true; updateFxMask() } }

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        // ❌ NEVER set cornerRadius or masksToBounds here.
        // Clipping is done via CAShapeLayer mask in updateFxMask().
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
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        // fx covers FULL bounds so it never clips the arrow area.
        fx.frame = bounds
        updateFxMask()
    }

    // MARK: - fx mask

    /// Applies a CAShapeLayer mask to fx so only the body + arrow shape
    /// is visible — identical to the path drawn in draw().
    /// This replaces the old cornerRadius/masksToBounds approach which
    /// clipped the arrow base and produced a visible cutout.
    private func updateFxMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let maskLayer = CAShapeLayer()
        maskLayer.path = chromePath(in: bounds).cgPath
        fx.layer?.mask = maskLayer
    }

    // MARK: - draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Slightly transparent fill so NSVisualEffectView shows through.
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.01)
            : NSColor(white: 0.95, alpha: 0.01)
        ctx.setFillColor(fill.cgColor)
        let path = chromePath(in: bounds)
        path.fill()
    }

    // MARK: - Shared path

    /// Single NSBezierPath describing the full chrome shape:
    /// rounded-rect body + upward arrow caret with cubic Bezier sides.
    /// Used for both draw() and the fx CAShapeLayer mask.
    ///
    /// Coordinate system: y=0 at BOTTOM, y=bounds.height at TOP.
    /// Arrow tip is at TOP (tipY = bounds.height).
    /// Body occupies y=0 … baseY where baseY = bounds.height - arrowHeight.
    /// overlapY = baseY - 1: arrow base extends 1pt into body → seamless join.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width
        let h = rect.height
        let r = cornerRadius
        let hw = arrowWidth / 2

        // Clamp arrow so caret never overlaps the rounded corners.
        let clampedX = max(hw + r, min(arrowX, w - hw - r))

        let baseY = h - arrowHeight   // top of body / base of arrow
        let tipY  = h                 // tip of arrow (top of view)
        let overlapY = baseY - 1      // 1pt inside body → no gap at join

        // Control point offset for cubic Bezier — gives the smooth
        // slightly-concave sides that match NSPopover’s caret style.
        let cp: CGFloat = 3

        let path = NSBezierPath()

        // Start at bottom-left corner and go clockwise.
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge + bottom-right corner
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r),
                       radius: r, startAngle: 270, endAngle: 0)

        // Right edge
        path.line(to: NSPoint(x: w, y: baseY - r))

        // Top-right corner
        path.appendArc(withCenter: NSPoint(x: w - r, y: baseY - r),
                       radius: r, startAngle: 0, endAngle: 90)

        // Top edge: right segment to arrow right base
        path.line(to: NSPoint(x: clampedX + hw, y: baseY))

        // Arrow right side → tip (cubic Bezier for smooth NSPopover shape)
        path.curve(to: NSPoint(x: clampedX, y: tipY),
                   controlPoint1: NSPoint(x: clampedX + hw,       y: overlapY + cp),
                   controlPoint2: NSPoint(x: clampedX + hw / 2,   y: tipY))

        // Arrow left side → left base
        path.curve(to: NSPoint(x: clampedX - hw, y: baseY),
                   controlPoint1: NSPoint(x: clampedX - hw / 2,   y: tipY),
                   controlPoint2: NSPoint(x: clampedX - hw,       y: overlapY + cp))

        // Top edge: left segment back to top-left corner
        path.line(to: NSPoint(x: r, y: baseY))

        // Top-left corner
        path.appendArc(withCenter: NSPoint(x: r, y: baseY - r),
                       radius: r, startAngle: 90, endAngle: 180)

        // Left edge
        path.line(to: NSPoint(x: 0, y: r))

        // Bottom-left corner back to start
        path.appendArc(withCenter: NSPoint(x: r, y: r),
                       radius: r, startAngle: 180, endAngle: 270)

        path.close()
        return path
    }
}
