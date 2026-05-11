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
// See: status-bar-app-position-warning.md §2 (NSPanel option)
//      issues #52 #54 #375 #376 #377
// ═══════════════════════════════════════════════════════════════════════════════

// ── Constants ────────────────────────────────────────────────────────────────
private let kCornerRadius:  CGFloat = 10   // matches NSPopover Sequoia
private let kArrowHeight:   CGFloat = 9
private let kArrowWidth:    CGFloat = 20
private let kArrowOverlapY: CGFloat = 1    // arrow base 1pt inside body — seamless join
private let kShadowRadius:  CGFloat = 20
private let kShadowAlpha:   Float   = 0.35

// ── NSBezierPath → CGPath helper (macOS 13 compatible) ───────────────────────
// NSBezierPath.cgPath is macOS 14+ only. This extension converts manually.
private extension NSBezierPath {
    var asCGPath: CGPath {
        let cg = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0 ..< elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:      cg.move(to: points[0])
            case .lineTo:      cg.addLine(to: points[0])
            case .curveTo:     cg.addCurve(to: points[2],
                                           control1: points[0],
                                           control2: points[1])
            case .cubicCurveTo: cg.addCurve(to: points[2],
                                            control1: points[0],
                                            control2: points[1])
            case .quadraticCurveTo: cg.addQuadCurve(to: points[1], control: points[0])
            case .closePath:   cg.closeSubpath()
            @unknown default:  break
            }
        }
        return cg
    }
}

final class PanelChrome: NSPanel {

    // The hosting view is embedded here by AppDelegate after init.
    var hostingView: NSView? {
        didSet {
            guard let hv = hostingView else { return }
            hv.autoresizingMask = [.width, .height]
            hv.frame = bodyRect(in: frame.size)
            contentView?.addSubview(hv)
        }
    }

    // Arrow tip X offset from panel left edge — set in positionBelow(button:).
    private var arrowTipX: CGFloat = 0

    // The visual-effect (blur) background layer.
    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material     = .menu
        v.blendingMode = .behindWindow
        v.state        = .active
        v.autoresizingMask = [.width, .height]
        return v
    }()

    // Outside-click monitor — replaces NSPopover .transient behaviour.
    private var outsideMonitor: Any?

    // Called by AppDelegate when the panel should close (outside click).
    var onClose: (() -> Void)?

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {
        super.init(
            contentRect: .zero,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel      = true
        level                = .statusBar
        backgroundColor      = .clear
        isOpaque             = false
        hasShadow            = false
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false

        fx.frame = NSRect(origin: .zero, size: .zero)
        contentView?.addSubview(fx)
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /// Position panel so arrow tip points at the centre of `button`, then show.
    func positionBelow(button: NSButton, contentHeight: CGFloat) {
        guard let buttonWindow = button.window else { return }
        let btnScreen  = buttonWindow.convertToScreen(button.frame)
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

    /// Resize panel height in-place — arrow tip stays pinned under button.
    func updateHeight(_ newContentHeight: CGFloat) {
        guard isVisible else { return }
        let totalHeight = newContentHeight + kArrowHeight
        let newOriginY  = frame.maxY - totalHeight
        setFrame(NSRect(x: frame.minX, y: newOriginY,
                        width: frame.width, height: totalHeight),
                 display: true)
        layoutChrome()
        hostingView?.frame = bodyRect(in: frame.size)
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

        fx.frame = NSRect(origin: .zero, size: size)
        hostingView?.frame = bodyRect(in: size)

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = chromePath(in: size).asCGPath   // macOS 13 safe
        fx.layer?.mask  = shapeLayer

        let shadow = NSShadow()
        shadow.shadowColor      = NSColor.black.withAlphaComponent(CGFloat(kShadowAlpha))
        shadow.shadowOffset     = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = kShadowRadius
        contentView?.shadow = shadow
    }

    private func bodyRect(in size: NSSize) -> NSRect {
        NSRect(x: 0, y: 0, width: size.width, height: size.height - kArrowHeight)
    }

    // ── Chrome path ──────────────────────────────────────────────────────────
    //
    //        arrowTip
    //         /    \
    //  ──────/      \──────   ← body top
    //  |  rounded body rect  |
    //  └────────────────────┘
    //
    private func chromePath(in size: NSSize) -> NSBezierPath {
        let w     = size.width
        let h     = size.height
        let bodyH = h - kArrowHeight
        let r     = kCornerRadius
        let aw    = kArrowWidth / 2
        let tipX  = arrowTipX
        let tipY  = h
        let baseY = bodyH + kArrowOverlapY

        let path = NSBezierPath()
        path.move(to: NSPoint(x: r, y: 0))
        path.line(to: NSPoint(x: w - r, y: 0))
        path.appendArc(withCenter: NSPoint(x: w - r, y: r), radius: r,
                       startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: w, y: bodyH - r))
        path.appendArc(withCenter: NSPoint(x: w - r, y: bodyH - r), radius: r,
                       startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: tipX + aw, y: bodyH))
        path.curve(to: NSPoint(x: tipX, y: tipY),
                   controlPoint1: NSPoint(x: tipX + aw * 0.6, y: baseY),
                   controlPoint2: NSPoint(x: tipX + aw * 0.2, y: tipY))
        path.curve(to: NSPoint(x: tipX - aw, y: bodyH),
                   controlPoint1: NSPoint(x: tipX - aw * 0.2, y: tipY),
                   controlPoint2: NSPoint(x: tipX - aw * 0.6, y: baseY))
        path.line(to: NSPoint(x: r, y: bodyH))
        path.appendArc(withCenter: NSPoint(x: r, y: bodyH - r), radius: r,
                       startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: 0, y: r))
        path.appendArc(withCenter: NSPoint(x: r, y: r), radius: r,
                       startAngle: 180, endAngle: 270)
        path.close()
        return path
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
