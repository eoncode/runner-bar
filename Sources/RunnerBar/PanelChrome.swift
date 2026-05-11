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
// COORDINATE SYSTEM (Y-up, origin at panel bottom-left):
//
//   totalHeight = contentHeight + kArrowHeight
//
//   panel.frame.maxY  ────  arrowTip  (points toward status bar button)
//                         /      \
//   bodyTop = contentH  ──────────  ← top of SwiftUI hosting view
//   |                              |
//   |   SwiftUI content (body)     |
//   |                              |
//   panel.frame.minY  ──────────
//
//   hostingView.frame.origin.y = 0   (bottom of panel = bottom of content)
//   hostingView.frame.size.height  = contentHeight  (NOT totalHeight)
//
// See: status-bar-app-position-warning.md §2 (NSPanel option)
//      issues #52 #54 #375 #376 #377
// ═══════════════════════════════════════════════════════════════════════════════

private let kCornerRadius:  CGFloat = 10
private let kArrowHeight:   CGFloat = 9
private let kArrowWidth:    CGFloat = 20
private let kArrowOverlapY: CGFloat = 1
private let kShadowRadius:  CGFloat = 20
private let kShadowAlpha:   Float   = 0.35

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
            hv.autoresizingMask = [.width, .height]
            hv.frame = bodyRect(in: frame.size)
            contentView?.addSubview(hv)
        }
    }

    private var arrowTipX: CGFloat = 0

    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material     = .menu
        v.blendingMode = .behindWindow
        v.state        = .active
        v.autoresizingMask = [.width, .height]
        return v
    }()

    private var outsideMonitor: Any?
    var onClose: (() -> Void)?

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel     = true
        level               = .statusBar
        backgroundColor     = .clear
        isOpaque            = false
        hasShadow           = false
        collectionBehavior  = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        fx.frame = NSRect(origin: .zero, size: .zero)
        contentView?.addSubview(fx)
    }

    // ── Public API ───────────────────────────────────────────────────────────

    func positionBelow(button: NSButton, contentHeight: CGFloat) {
        guard let bw = button.window else { return }
        let btnScreen  = bw.convertToScreen(button.frame)
        let btnCentreX = btnScreen.midX
        let totalHeight = contentHeight + kArrowHeight
        let panelWidth  = AppDelegate.fixedWidth

        var originX = btnCentreX - panelWidth / 2
        if let screen = NSScreen.main {
            originX = max(screen.visibleFrame.minX,
                         min(originX, screen.visibleFrame.maxX - panelWidth))
        }
        let originY = btnScreen.minY - totalHeight
        arrowTipX = btnCentreX - originX

        setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: totalHeight),
                 display: false)
        layoutChrome()
        orderFront(nil)
        makeKey()
        installOutsideMonitor()
    }

    /// Resize in-place. Top edge (arrow) stays fixed. Only bottom moves.
    func updateHeight(_ newContentHeight: CGFloat) {
        guard isVisible else { return }
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

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutChrome()
    }

    private func layoutChrome() {
        let size = frame.size
        guard size.width > 0, size.height > 0 else { return }

        // fx covers full panel (body + arrow region) for the mask.
        fx.frame = NSRect(origin: .zero, size: size)

        // Hosting view sits in the body only (below the arrow).
        hostingView?.frame = bodyRect(in: size)

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = chromePath(in: size).asCGPath
        fx.layer?.mask  = shapeLayer

        let shadow = NSShadow()
        shadow.shadowColor      = NSColor.black.withAlphaComponent(CGFloat(kShadowAlpha))
        shadow.shadowOffset     = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = kShadowRadius
        contentView?.shadow = shadow
    }

    // Body rect: y=0 (panel bottom), height=contentHeight.
    // Arrow lives above bodyTop — hosting view must NOT extend into it.
    private func bodyRect(in size: NSSize) -> NSRect {
        NSRect(x: 0, y: 0, width: size.width, height: size.height - kArrowHeight)
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
        p.appendArc(withCenter: NSPoint(x: w - r, y: r), radius: r, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: w, y: bodyH - r))
        p.appendArc(withCenter: NSPoint(x: w - r, y: bodyH - r), radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: tipX + aw, y: bodyH))
        p.curve(to: NSPoint(x: tipX, y: tipY),
                controlPoint1: NSPoint(x: tipX + aw * 0.6, y: baseY),
                controlPoint2: NSPoint(x: tipX + aw * 0.2, y: tipY))
        p.curve(to: NSPoint(x: tipX - aw, y: bodyH),
                controlPoint1: NSPoint(x: tipX - aw * 0.2, y: tipY),
                controlPoint2: NSPoint(x: tipX - aw * 0.6, y: baseY))
        p.line(to: NSPoint(x: r, y: bodyH))
        p.appendArc(withCenter: NSPoint(x: r, y: bodyH - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: 0, y: r))
        p.appendArc(withCenter: NSPoint(x: r, y: r), radius: r, startAngle: 180, endAngle: 270)
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
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }
}
