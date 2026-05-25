// PanelChrome.swift
// RunnerBar
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
//     cp2 = (cX - w/5, baseY+arrowH)     — near-tip anchor
//
//   Right bezier: toPoint → rightPoint
//     cp1 = (cX + w/5, baseY+arrowH)     — near-tip anchor (mirror)
//     cp2 = (cX + w/6, baseY)            — concave foot anchor
//
// With arrowWidth=30: cpFoot=w/6=5pt, cpTip=w/5=6pt.
// Tip CPs are 12pt apart at tipY => soft rounded arch matching NSPopover Sequoia.
//
// ❌ NEVER change cpTip back to w/9 (3.33pt) — tip CPs 6.67pt apart => pointy apex.
// ❌ NEVER change cpTip to hw (15pt) — too wide, outward blob.
// ❌ NEVER add a separate tip arc — the two-bezier meeting at toPoint IS the rounded tip.
// ❌ NEVER use straight lines — flat / no concavity.
// ❌ NEVER use appendArc at BASE corners — visible base humps.
//
// KEY FACTS:
//
// 1. macOS coordinate system: y=0 is BOTTOM of view, y=bounds.height is TOP.
//    Arrow tip is at TOP. contentRect = (0, 0, w, h - arrowHeight).
//
// 2. fxView (NSVisualEffectView on <26, NSGlassEffectView on 26+) covers FULL bounds.
//    Body-shape clipping via CAShapeLayer mask on fxView.layer.
//    Rebuilt on every layout() + arrowX change.
//    ❌ NEVER set cornerRadius or masksToBounds on fxView.layer directly.
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
// NSGLASS COMPOSITOR WARM-UP (fix #891/#893):
// On cold open, NSGlassEffectView samples the compositor BEFORE NSHostingController
// has flushed its first render. The backdrop sampler sees an incomplete/grey stack.
// Fix: viewDidMoveToWindow() defers one run-loop tick, then sets needsLayout=true
// on both self and fxView. This forces a full layout+composite pass with the real
// SwiftUI content stack present, so NSGlassEffectView re-samples correctly.
// ❌ NEVER remove viewDidMoveToWindow() — cold-open grey regression is immediate.
// ❌ NEVER make the call synchronous — fires before SwiftUI has flushed to compositor.
// ❌ NEVER remove the fxView.needsLayout line — fxView must also re-layout to resample.
//
// ❌ NEVER remove this file. Regression is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

/// Height of the arrow tip above the panel body, in points.
let arrowHeight: CGFloat = 9  // shallower = flatter arch, matches original NSPopover
/// Width of the arrow base, in points.
let arrowWidth: CGFloat = 30  // wider base, matches original NSPopover
/// Corner radius of the panel body, matching native NSPopover.
let cornerRadius: CGFloat = 10  // matches NSPopover body corner

// MARK: - NSBezierPath → CGPath (macOS 13 compatible)
// ❌ NEVER replace with .cgPath — requires macOS 14+.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
/// macOS 13-compatible `CGPath` conversion for `NSBezierPath`.
private extension NSBezierPath {
    /// Converts this `NSBezierPath` to a `CGPath` without using `.cgPath` (macOS 14+).
    var compatCGPath: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for idx in 0 ..< elementCount {
            switch element(at: idx, associatedPoints: &pts) {
            case .moveTo:
                path.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
            case .lineTo:
                path.addLine(to: CGPoint(x: pts[0].x, y: pts[0].y))
            case .curveTo:
                path.addCurve(
                    to: CGPoint(x: pts[2].x, y: pts[2].y),
                    control1: CGPoint(x: pts[0].x, y: pts[0].y),
                    control2: CGPoint(x: pts[1].x, y: pts[1].y)
                )
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(
                    to: CGPoint(x: pts[2].x, y: pts[2].y),
                    control1: CGPoint(x: pts[0].x, y: pts[0].y),
                    control2: CGPoint(x: pts[1].x, y: pts[1].y)
                )
            case .quadraticCurveTo:
                path.addQuadCurve(
                    to: CGPoint(x: pts[1].x, y: pts[1].y),
                    control: CGPoint(x: pts[0].x, y: pts[0].y)
                )
            @unknown default:
                break
            }
        }
        return path
    }
}

/// Custom `NSView` that renders the HUD panel chrome: vibrancy/glass background, rounded corners, and the arrow pointer.
final class PanelChromeView: NSView {
    /// Panel-local X of arrow tip centre.
    /// Formula: button.window!.frame.midX - panel.frame.minX
    /// ❌ NEVER compute from convertToScreen(button.frame).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    var arrowX: CGFloat = 240 {
        didSet { needsDisplay = true; updateFxMask() }
    }

    // MARK: - Background effect view (OS-branched)
    //
    // macOS 26+: NSGlassEffectView provides Liquid Glass backdrop.
    //   cornerRadius is set to match the panel body (10pt).
    //   The same CAShapeLayer mask (updateFxMask) clips it to the arrow+body shape.
    //
    // macOS < 26: NSVisualEffectView with .hudWindow material (existing behaviour).
    //
    // ❌ NEVER apply glass on macOS < 26 — NSGlassEffectView does not exist there.
    // ❌ NEVER remove the NSVisualEffectView fallback path.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.

    /// The backing effect view. On macOS 26+ this is an `NSGlassEffectView`;
    /// on macOS < 26 it is an `NSVisualEffectView` with `.hudWindow` material.
    private let fxView: NSView

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            // Liquid Glass chrome — NSGlassEffectView.
            // cornerRadius matches the panel body constant (10pt).
            // The CAShapeLayer mask applied in updateFxMask() clips the glass to
            // the full arrow+body bezier shape, so the system corner clipping is
            // supplementary rather than authoritative.
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            glassView.wantsLayer = true
            fxView = glassView
        } else {
            // Legacy HUD vibrancy — unchanged from original implementation.
            // .hudWindow gives a cool dark translucent look — no warm tint.
            // .popover has a warm cream tint in dark mode which is undesirable.
            // ❌ NEVER switch back to .popover — it produces a warm brown tint on dark wallpapers.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
            let vibrancyView = NSVisualEffectView()
            vibrancyView.material = .hudWindow
            vibrancyView.blendingMode = .behindWindow
            vibrancyView.state = .active
            vibrancyView.wantsLayer = true
            fxView = vibrancyView
        }
        super.init(frame: frame)
        wantsLayer = true
        // ❌ NEVER set layer?.backgroundColor = CGColor.clear (alpha 0.0).
        // alpha=0.0 disables CABackdropLayer — vibrancy/glass collapses to flat grey.
        // Near-zero (0.001) keeps the backdrop sampler active.
        // Verified: this contract holds for both NSVisualEffectView and NSGlassEffectView.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        layer?.backgroundColor = CGColor(gray: 1, alpha: 0.001)
        addSubview(fxView)
    }

    /// Not implemented — this view is only created programmatically.
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Glass compositor warm-up (fix #891/#893)
    //
    // On cold open, NSGlassEffectView is attached to the window BEFORE the SwiftUI
    // NSHostingController has flushed its first render into the compositor.
    // NSGlassEffectView samples an incomplete/thin content stack and renders grey.
    //
    // Fix: defer one run-loop turn after viewDidMoveToWindow so the hosting controller
    // has flushed, then mark both self and fxView as needing layout. This forces a
    // full layout+composite pass with the complete SwiftUI content stack present,
    // so NSGlassEffectView re-samples correctly and renders dark on the first frame.
    //
    // ❌ NEVER remove this override — cold-open grey regression is immediate.
    // ❌ NEVER make the dispatches synchronous — SwiftUI hasn't flushed yet at that point.
    // ❌ NEVER remove fxView.needsLayout — fxView must re-layout to trigger re-sampling.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsLayout = true
            self.fxView.needsLayout = true
        }
    }

    /// The rectangle occupied by the panel body (excluding the arrow tip area).
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        fxView.frame = bounds
        updateFxMask()
        // Re-pin ALL non-fx subviews to contentRect on EVERY layout pass.
        // ❌ NEVER set hosting view frame only at init — dynamic height breaks.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        for sub in subviews where sub !== fxView {
            sub.frame = contentRect
        }
    }

    /// Recomputes and applies the CAShapeLayer mask that clips the effect view to the chrome path.
    /// Applied to both NSGlassEffectView (macOS 26+) and NSVisualEffectView (macOS < 26).
    private func updateFxMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let maskLayer = CAShapeLayer()
        maskLayer.path = chromePath(in: bounds).compatCGPath
        fxView.layer?.mask = maskLayer
    }

    override func draw(_ dirtyRect: NSRect) {
        // fix(#891): On macOS 26+, NSGlassEffectView owns all visual rendering.
        // The legacy grey fill (white: 0.18, alpha: 0.01) is imperceptible on
        // macOS < 26 but composites visibly over NSGlassEffectView on cold open
        // before the backdrop sampler has acquired real desktop content.
        // On Settings → Main navigation the wallpaper bleed-through overpowers
        // the fill, masking the bug. Skip entirely on macOS 26+.
        // ❌ NEVER remove this guard — restoring the fill on 26+ reintroduces the grey tint.
        guard #unavailable(macOS 26) else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark ? NSColor(white: 0.18, alpha: 0.01) : NSColor(white: 0.95, alpha: 0.01)
        ctx.setFillColor(fill.cgColor)
        chromePath(in: bounds).fill()
    }

    // MARK: - Chrome path
    //
    // iSapozhnik two-bezier arrow with adjusted cpTip fraction.
    //
    // Left bezier:  leftPoint → toPoint,  cp1=(cX-w/6, baseY), cp2=(cX-w/5, tipY)
    // Right bezier: toPoint  → rightPoint, cp1=(cX+w/5, tipY),  cp2=(cX+w/6, baseY)
    //
    // cpFoot = w/6 = 5pt  (concave foot anchor)
    // cpTip  = w/5 = 6pt  (near-tip anchor, 12pt spread => soft rounded arch)
    //
    // ❌ NEVER set cpTip = w/9 (pointy) or hw (blob).
    // ❌ NEVER add a tip arc.
    // ❌ NEVER use appendArc at BASE corners.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    /// Builds the rounded-rect + upward arrow bezier path used for both masking and drawing the panel chrome.
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let width     = rect.width
        let height    = rect.height
        let rad       = cornerRadius
        let halfWidth = arrowWidth / 2
        let centreX   = max(halfWidth + rad, min(arrowX, width - halfWidth - rad))
        let baseY     = height - arrowHeight
        let tipY      = height
        let cpFoot    = arrowWidth / 6  // 5pt — concave foot anchor
        let cpTip     = arrowWidth / 5  // 6pt — near-tip anchor, 12pt spread => soft arch
        // ❌ NEVER change cpTip to w/9 (pointy) or hw (15pt, blob).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.

        let leftPoint  = NSPoint(x: centreX - halfWidth, y: baseY)
        let toPoint    = NSPoint(x: centreX, y: tipY)
        let rightPoint = NSPoint(x: centreX + halfWidth, y: baseY)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rad, y: 0))
        path.line(to: NSPoint(x: width - rad, y: 0))
        path.appendArc(withCenter: NSPoint(x: width - rad, y: rad), radius: rad, startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: width, y: baseY - rad))
        path.appendArc(withCenter: NSPoint(x: width - rad, y: baseY - rad), radius: rad, startAngle: 0, endAngle: 90)
        path.line(to: rightPoint)
        path.curve(
            to: toPoint,
            controlPoint1: NSPoint(x: centreX + cpFoot, y: baseY),
            controlPoint2: NSPoint(x: centreX + cpTip, y: tipY)
        )
        path.curve(
            to: leftPoint,
            controlPoint1: NSPoint(x: centreX - cpTip, y: tipY),
            controlPoint2: NSPoint(x: centreX - cpFoot, y: baseY)
        )
        path.line(to: NSPoint(x: rad, y: baseY))
        path.appendArc(withCenter: NSPoint(x: rad, y: baseY - rad), radius: rad, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: 0, y: rad))
        path.appendArc(withCenter: NSPoint(x: rad, y: rad), radius: rad, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }
}
