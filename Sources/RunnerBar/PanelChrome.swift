import AppKit

// MARK: - PanelChrome
//
// Provides the visual chrome for the NSPanel, matching NSPopover appearance exactly:
//   1. NSVisualEffectView background (hudWindow material)
//   2. cornerRadius = 8pt  (matches NSPopover on macOS)
//   3. Arrow caret: arrowHeight=12pt, arrowWidth=20pt, cubic Bézier tip
//      (same control-point math as NSPopoverFrame private draw method)
//
// arrowX positioning (CRITICAL):
//   arrowX = statusItemButtonWindow.frame.midX - panel.frame.minX
//   button.window?.frame is ALREADY in screen coords.
//   ❌ NEVER use convertToScreen(button.frame) — button.frame is button-local,
//      convertToScreen gives wrong screen X and misaligns the arrow.
//
// Layout:
//   chrome IS the panel contentView. AppKit owns chrome.frame.
//   ❌ NEVER set chrome.frame manually from AppDelegate.
//   chrome.layout() re-pins fx + hosting view to contentRect on every layout pass.
//   contentRect = NSRect(x:0, y:0, width:bounds.width, height:bounds.height - arrowHeight)
//
// ❌ NEVER remove this file.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression is major major major.

let arrowHeight: CGFloat = 12   // matches NSPopover standard
let arrowWidth:  CGFloat = 20   // matches NSPopover standard
let cornerRadius: CGFloat = 8   // matches NSPopover standard macOS cornerRadius

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
        fx.frame = contentRect
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        for sub in subviews where sub !== fx {
            sub.frame = contentRect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Arrow: cubic Bézier, matching NSPopoverFrame internal draw math.
        // iSapozhnik/Popover reverse-engineered these control points from NSPopover.
        // cp offsets: arrowWidth/6 horizontally, arrowWidth/9 vertically.
        let cX = max(arrowWidth / 2 + cornerRadius,
                     min(arrowX, bounds.width - arrowWidth / 2 - cornerRadius))
        let baseY = bounds.height - arrowHeight   // top of content rect
        let tipY  = bounds.height                 // very top of view

        let leftPt  = CGPoint(x: cX - arrowWidth / 2, y: baseY)
        let tipPt   = CGPoint(x: cX,                  y: tipY)
        let rightPt = CGPoint(x: cX + arrowWidth / 2, y: baseY)

        // Control points for smooth rounded tip (Bézier, not addArc)
        let cp1a = CGPoint(x: cX - arrowWidth / 6, y: baseY)
        let cp1b = CGPoint(x: cX - arrowWidth / 9, y: tipY)
        let cp2a = CGPoint(x: cX + arrowWidth / 9, y: tipY)
        let cp2b = CGPoint(x: cX + arrowWidth / 6, y: baseY)

        let path = CGMutablePath()
        path.move(to: leftPt)
        path.addCurve(to: tipPt,   control1: cp1a, control2: cp1b)
        path.addCurve(to: rightPt, control1: cp2a, control2: cp2b)
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
