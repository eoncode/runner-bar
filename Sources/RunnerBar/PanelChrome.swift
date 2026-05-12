import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// PanelChrome — NSPanel replacement for NSPopover
//
// WHY: NSPopover re-anchors (left-jumps) on any contentSize change while shown.
// There is no public API to prevent this. By owning the window we own the
// position — updateHeight() resizes the panel in-place and the arrow stays
// pinned to the status bar button centre. No re-anchor is possible.
//
// COORDINATE SYSTEM (macOS is Y-up; origin at BOTTOM-LEFT of screen):
//
//   panel.frame.maxY  ────  arrowTip  (near status bar, HIGH Y value)
//                         /      \
//   arrowBase = maxY – kArrowHeight
//   |                              |
//   |   SwiftUI hosting view       |
//   |   (bodyHeight = contentH)    |
//   |                              |
//   panel.frame.minY  ──────────  (LOW Y value, further down screen)
//
//   hostingView.frame = (x:0, y:0, w:panelWidth, h:contentHeight)
//   Arrow region occupies the TOP kArrowHeight pts of the panel frame.
//
// SIZING CONTRACT:
//   positionBelow() receives the REAL contentHeight (from sizeThatFits).
//   updateHeight() receives updated contentHeight after navigation/data.
//   ❌ NEVER pass a hardcoded/placeholder height to positionBelow().
// ═══════════════════════════════════════════════════════════════════════════════

private let kCornerRadius:  CGFloat = 10
private let kArrowHeight:   CGFloat = 9
private let kArrowWidth:    CGFloat = 20
private let kArrowOverlapY: CGFloat = 1
private let kShadowRadius:  CGFloat = 20
private let kShadowAlpha:   Float   = 0.35
private let kBorderWidth:   CGFloat = 0.5
private let kBorderAlpha:   CGFloat = 0.4
private let kHeightEpsilon: CGFloat = 1.0

// NSBezierPath → CGPath (macOS 13 compatible — .cgPath is macOS 14+ only)
private extension NSBezierPath {
    var asCGPath: CGPath {
        let cg = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0 ..< elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:           cg.move(to: pts[0])
            case .lineTo:           cg.addLine(to: pts[0])
            case .curveTo,
                 .cubicCurveTo:     cg.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: cg.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath:        cg.closeSubpath()
            @unknown default:       break
            }
        }
        return cg
    }
}

final class PanelChrome: NSPanel {

    var hostingView: NSView? {
        didSet {
            guard let hv = hostingView else { return }
            hv.autoresizingMask = []
            contentView?.addSubview(hv)
        }
    }

    private var arrowTipX: CGFloat = 0
    private var lastLayoutSize: NSSize = .zero

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material     = .popover
        v.blendingMode = .behindWindow
        v.state        = .active
        v.autoresizingMask = []
        return v
    }()

    // ⚠️ BORDER: CAShapeLayer added as sublayer of fx.layer (above the mask).
    // fx.layer?.mask clips the visual effect; borderLayer is a sibling sublayer
    // of that mask — it sits inside the clipped region and strokes the outline.
    // Adding to fx.layer (not contentView.layer) guarantees it is clipped to
    // the chrome shape and always visible above the frosted background.
    private let borderLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor   = CGColor.clear
        l.lineWidth   = kBorderWidth
        l.strokeColor = NSColor.separatorColor.withAlphaComponent(kBorderAlpha).cgColor
        return l
    }()

    private var outsideMonitor: Any?
    var onClose: (() -> Void)?

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel    = true
        level              = .statusBar
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = CGColor.clear
        contentView?.addSubview(fx)
        // borderLayer is inserted into fx after fx gets its layer in layoutChrome.
    }

    // ── Public API ───────────────────────────────────────────────────────────

    func positionBelow(button: NSButton, contentHeight: CGFloat) {
        guard let bw = button.window else { return }
        let btnInWindow = button.convert(button.bounds, to: nil)
        let btnScreen   = bw.convertToScreen(btnInWindow)
        let btnCentreX  = btnScreen.midX
        let totalHeight = contentHeight + kArrowHeight
        let panelWidth  = AppDelegate.fixedWidth

        var originX = btnCentreX - panelWidth / 2
        if let screen = NSScreen.main {
            originX = max(screen.visibleFrame.minX,
                         min(originX, screen.visibleFrame.maxX - panelWidth))
        }
        let originY = btnScreen.minY - totalHeight
        arrowTipX = btnCentreX - originX

        lastLayoutSize = .zero
        setFrame(NSRect(x: originX, y: originY,
                        width: panelWidth, height: totalHeight),
                 display: false)
        layoutChrome()
        orderFront(nil)
        makeKey()
        installOutsideMonitor()
    }

    /// No-op if height change ≤ kHeightEpsilon — prevents flicker from rapid
    /// HeightReporter callbacks when content height hasn't meaningfully changed.
    func updateHeight(_ newContentHeight: CGFloat) {
        guard isVisible else { return }
        let currentContentHeight = frame.height - kArrowHeight
        guard abs(newContentHeight - currentContentHeight) > kHeightEpsilon else { return }
        let totalHeight = newContentHeight + kArrowHeight
        let newOriginY  = frame.maxY - totalHeight
        setFrame(NSRect(x: frame.minX, y: newOriginY,
                        width: frame.width, height: totalHeight),
                 display: true)
        layoutChrome()
    }

    func closePanel() {
        removeOutsideMonitor()
        orderOut(nil)
        onClose?()
    }

    // ── Layout ───────────────────────────────────────────────────────────────

    private func layoutChrome() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }

        let contentH = size.height - kArrowHeight

        fx.frame = NSRect(origin: .zero, size: size)
        hostingView?.frame = NSRect(x: 0, y: 0, width: size.width, height: contentH)

        guard size != lastLayoutSize else { return }
        lastLayoutSize = size

        let path = chromePath(in: size).asCGPath

        // Mask clips fx to the chrome shape.
        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        fx.layer?.mask = maskLayer

        // ⚠️ Border: add borderLayer as a regular sublayer of fx.layer.
        // It is NOT the mask — it strokes the path on top of the frosted glass.
        // We remove+re-add to avoid accumulating duplicate sublayers on resize.
        borderLayer.removeFromSuperlayer()
        borderLayer.path  = path
        borderLayer.frame = NSRect(origin: .zero, size: size)
        fx.layer?.addSublayer(borderLayer)

        let shadow = NSShadow()
        shadow.shadowColor      = NSColor.black.withAlphaComponent(CGFloat(kShadowAlpha))
        shadow.shadowOffset     = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = kShadowRadius
        contentView?.shadow = shadow
    }

    // ── Chrome path ──────────────────────────────────────────────────────────

    private func chromePath(in size: NSSize) -> NSBezierPath {
        let w = size.width, h = size.height
        let bodyH = h - kArrowHeight
        let r = kCornerRadius, aw = kArrowWidth / 2
        let tipX = arrowTipX, tipY = h
        let baseY = bodyH + kArrowOverlapY

        let p = NSBezierPath()
        p.move(to: NSPoint(x: r, y: 0))
        p.line(to: NSPoint(x: w - r, y: 0))
        p.appendArc(withCenter: NSPoint(x: w - r, y: r),
                    radius: r, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: w, y: bodyH - r))
        p.appendArc(withCenter: NSPoint(x: w - r, y: bodyH - r),
                    radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: tipX + aw, y: bodyH))
        p.curve(to: NSPoint(x: tipX, y: tipY),
                controlPoint1: NSPoint(x: tipX + aw * 0.6, y: baseY),
                controlPoint2: NSPoint(x: tipX + aw * 0.2, y: tipY))
        p.curve(to: NSPoint(x: tipX - aw, y: bodyH),
                controlPoint1: NSPoint(x: tipX - aw * 0.2, y: tipY),
                controlPoint2: NSPoint(x: tipX - aw * 0.6, y: baseY))
        p.line(to: NSPoint(x: r, y: bodyH))
        p.appendArc(withCenter: NSPoint(x: r, y: bodyH - r),
                    radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: 0, y: r))
        p.appendArc(withCenter: NSPoint(x: r, y: r),
                    radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    // ── Outside-click dismissal ───────────────────────────────────────────────

    private func installOutsideMonitor() {
        removeOutsideMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            let loc = event.locationInWindow
            let screenLoc: NSPoint
            if let w = event.window {
                screenLoc = w.convertToScreen(NSRect(origin: loc, size: .zero)).origin
            } else {
                screenLoc = loc
            }
            if !self.frame.contains(screenLoc) { self.closePanel() }
        }
    }

    private func removeOutsideMonitor() {
        if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
    }
}
