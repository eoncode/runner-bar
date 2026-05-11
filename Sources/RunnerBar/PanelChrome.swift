import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly:
//   1. NSVisualEffectView background (hudWindow material)
//   2. cornerRadius = 8pt  (matches NSPopover on macOS)
//   3. Arrow caret: arrowHeight=12pt, arrowWidth=20pt
//      Shape: isoceles triangle with addArc(radius:2) at tip — matches NSPopover at 20×12pt.
//      (Cubic Bézier control points only look correct at large arrowWidth like 60pt;
//       at 20pt they produce a needle shape. Use addArc for tight dimensions.)
//
// arrowX positioning (CRITICAL):
//   arrowX = button.window!.frame.midX - panel.frame.minX
//   button.window?.frame is ALREADY in screen coords.
//   ❌ NEVER use convertToScreen(button.frame) — button.frame is button-local,
//      convertToScreen gives wrong screen X and misaligns the arrow.
//
// Layout:
//   chrome IS the panel contentView. AppKit owns chrome.frame.
//   ❌ NEVER set chrome.frame manually from AppDelegate.
//   layout() pins fx + hosting view to contentRect on EVERY layout pass.
//   contentRect = NSRect(x:0, y:0, width:bounds.width, height:bounds.height - arrowHeight)
//   hosting view also has autoresizingMask = [.width, .height] for AppKit resize passes.
//
// Dynamic height:
//   AppDelegate KVO on preferredContentSize → resizeAndRepositionPanel() → panel.setFrame().
//   panel.setFrame() → AppKit resizes contentView (chrome) → layout() → hosting view grows.
//   hosting view frame = contentRect grows → SwiftUI renders at new height.
//   ❌ NEVER set hostingController.view.frame only once at init — it won't update on resize.
//
// ❌ NEVER remove this file.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight: CGFloat = 12   // matches NSPopover standard
let arrowWidth:  CGFloat = 20   // matches NSPopover standard
let cornerRadius: CGFloat = 8   // matches NSPopover standard macOS

final class PanelChromeView: NSView {

    /// Panel-local X of arrow tip centre.
    /// Formula: button.window!.frame.midX - panel.frame.minX
    /// ❌ NEVER compute from convertToScreen(button.frame) — button.frame is button-local.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    var arrowX: CGFloat = 240 { didSet { needsDisplay = true } }

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

    /// Content rect: full bounds minus arrowHeight at top (macOS: y=0 is bottom).
    var contentRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - arrowHeight))
    }

    override func layout() {
        super.layout()
        // Re-pin every subview to contentRect on EVERY layout pass.
        // ❌ NEVER only set frames once at init — panel resize won't propagate.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression is major major major.
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Arrow shape: isoceles triangle with addArc(radius:2) at the tip.
        //
        // Why NOT cubic Bézier here:
        //   iSapozhnik control points (width/6, width/9) look correct at arrowWidth≈60pt.
        //   At arrowWidth=20pt the same ratios give an almost-straight needle shape.
        //   NSPopover's actual 20×12 arrow is a triangle + small rounded tip.
        //   addArc(radius:2) at the tip matches NSPopover visually at these dimensions.
        //
        // Geometry (macOS: y=0 is bottom, y increases upward):
        //   baseY = top of content rect (= bounds.height - arrowHeight)
        //   tipY  = very top of view    (= bounds.height)
        //   cX    = clamped panel-local X of arrow centre

        let cX    = max(arrowWidth / 2 + cornerRadius,
                        min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius))
        let baseY = bounds.height - arrowHeight
        let tipY  = bounds.height

        let leftPt  = CGPoint(x: cX - arrowWidth / 2, y: baseY)
        let tipPt   = CGPoint(x: cX,                  y: tipY)
        let rightPt = CGPoint(x: cX + arrowWidth / 2, y: baseY)

        // Compute the unit vectors along each slope for the addArc tangent approach.
        // Left slope: from leftPt toward tipPt
        let dxL = tipPt.x - leftPt.x
        let dyL = tipPt.y - leftPt.y
        let lenL = sqrt(dxL * dxL + dyL * dyL)
        // Right slope: from rightPt toward tipPt
        let dxR = tipPt.x - rightPt.x
        let dyR = tipPt.y - rightPt.y
        let lenR = sqrt(dxR * dxR + dyR * dyR)

        // Tip arc radius: 2pt — gives NSPopover's characteristic slight rounding.
        let tipRadius: CGFloat = 2

        // Tangent points: step back tipRadius/sin(half-angle) from the tip along each slope.
        // For a 20×12 arrow, half-angle ≈ 40°, so the step-back ≈ 3pt.
        let sinHalfAngle = (arrowWidth / 2) / sqrt((arrowWidth / 2) * (arrowWidth / 2) + arrowHeight * arrowHeight)
        let stepBack = tipRadius / sinHalfAngle
        let tangentL = CGPoint(x: tipPt.x - (dxL / lenL) * stepBack,
                               y: tipPt.y - (dyL / lenL) * stepBack)
        let tangentR = CGPoint(x: tipPt.x - (dxR / lenR) * stepBack,
                               y: tipPt.y - (dyR / lenR) * stepBack)

        let path = CGMutablePath()
        path.move(to: leftPt)
        path.addLine(to: tangentL)
        path.addArc(tangent1End: tipPt, tangent2End: tangentR, radius: tipRadius)
        path.addLine(to: rightPt)
        path.closeSubpath()

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.97)
            : NSColor(white: 0.96, alpha: 0.97)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
}
