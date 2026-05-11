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

final class PanelChrome: NSPanel {

    // The hosting view is embedded here by AppDelegate after init.
    var hostingView: NSView? {
        didSet {
            guard let hv = hostingView else { return }
            hv.autoresizingMask = [.width, .height]
            // Place inside body rect (below arrow).
            hv.frame = bodyRect(in: frame.size)
            contentView?.addSubview(hv)
        }
    }

    // Arrow tip X offset from panel left edge — set in positionBelow(button:).
    private var arrowTipX: CGFloat = 0

    // The visual-effect (blur) background layer.
    private let fx: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material   = .menu
        v.blendingMode = .behindWindow
        v.state      = .active
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
        hasShadow            = false   // we draw our own shadow via NSShadow
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false

        // fx fills the entire panel frame (body + arrow area).
        fx.frame = NSRect(origin: .zero, size: .zero)   // sized in layout()
        contentView?.addSubview(fx)
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /// Position panel so arrow tip points at the centre of `button`,
    /// then show the panel. Call while panel is hidden.
    func positionBelow(button: NSButton, contentHeight: CGFloat) {
        guard let buttonWindow = button.window else { return }
        // Button frame in screen coordinates.
        let btnScreen = buttonWindow.convertToScreen(button.frame)
        let btnCentreX = btnScreen.midX

        let totalHeight = contentHeight + kArrowHeight
        let panelWidth  = AppDelegate.fixedWidth

        // X: arrow tip centred on button, panel kept on-screen.
        var originX = btnCentreX - panelWidth / 2
        if let screen = NSScreen.main {
            originX = max(screen.visibleFrame.minX,
                         min(originX, screen.visibleFrame.maxX - panelWidth))
        }
        // Y: panel top = button bottom (arrow points up).
        let originY = btnScreen.minY - totalHeight

        arrowTipX = btnCentreX - originX

        setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: totalHeight),
                 display: false)
        layoutChrome()
        orderFront(nil)
        makeKey()
        installOutsideMonitor()
    }

    /// Resize panel height without moving the arrow tip.
    /// Safe to call while panel is visible — we own the position.
    func updateHeight(_ newContentHeight: CGFloat) {
        guard isVisible else { return }
        let totalHeight = newContentHeight + kArrowHeight
        let panelWidth  = frame.width
        // Keep top-left corner fixed (arrow stays under button).
        let newOriginY  = frame.maxY - totalHeight
        setFrame(NSRect(x: frame.minX, y: newOriginY,
                        width: panelWidth, height: totalHeight),
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

        // Build chrome path and apply as mask.
        let path = chromePath(in: size)
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path.cgPath
        fx.layer?.mask = shapeLayer

        // Shadow on the panel's contentView layer.
        let shadow = NSShadow()
        shadow.shadowColor  = NSColor.black.withAlphaComponent(CGFloat(kShadowAlpha))
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = kShadowRadius
        contentView?.shadow = shadow
    }

    // The rect occupied by the body (everything below the arrow tip).
    private func bodyRect(in size: NSSize) -> NSRect {
        NSRect(x: 0, y: 0, width: size.width, height: size.height - kArrowHeight)
    }

    // ── Chrome path ──────────────────────────────────────────────────────────
    //
    // Coordinate system: origin at panel bottom-left, Y up.
    // Arrow points upward. Body is below the arrow.
    //
    //        arrowTip
    //         /    \
    //  ──────/      \──────   ← arrowBaseY  (= totalHeight - arrowHeight + overlapY)
    //  |  rounded body rect  |
    //  └────────────────────┘
    //
    private func chromePath(in size: NSSize) -> NSBezierPath {
        let w = size.width
        let h = size.height
        let bodyH   = h - kArrowHeight
        let r       = kCornerRadius
        let aw      = kArrowWidth / 2   // half-width
        let tipX    = arrowTipX         // tip X from left edge
        let tipY    = h                 // tip at top of panel
        let baseY   = bodyH + kArrowOverlapY   // base slightly inside body

        let path = NSBezierPath()
        // Start at bottom-left corner (after corner radius).
        path.move(to: NSPoint(x: r, y: 0))

        // Bottom edge → right.
        path.line(to: NSPoint(x: w - r, y: 0))
        // Bottom-right corner.
        path.appendArc(withCenter: NSPoint(x: w - r, y: r), radius: r,
                       startAngle: 270, endAngle: 0)
        // Right edge → top-right corner.
        path.line(to: NSPoint(x: w, y: bodyH - r))
        // Top-right corner.
        path.appendArc(withCenter: NSPoint(x: w - r, y: bodyH - r), radius: r,
                       startAngle: 0, endAngle: 90)
        // Top edge right segment → arrow right base.
        path.line(to: NSPoint(x: tipX + aw, y: bodyH))
        // Arrow right side (cubic Bezier — smooth caret matching NSPopover).
        path.curve(to:          NSPoint(x: tipX, y: tipY),
                   controlPoint1: NSPoint(x: tipX + aw * 0.6, y: baseY),
                   controlPoint2: NSPoint(x: tipX + aw * 0.2, y: tipY))
        // Arrow left side.
        path.curve(to:          NSPoint(x: tipX - aw, y: bodyH),
                   controlPoint1: NSPoint(x: tipX - aw * 0.2, y: tipY),
                   controlPoint2: NSPoint(x: tipX - aw * 0.6, y: baseY))
        // Top edge left segment → top-left corner.
        path.line(to: NSPoint(x: r, y: bodyH))
        // Top-left corner.
        path.appendArc(withCenter: NSPoint(x: r, y: bodyH - r), radius: r,
                       startAngle: 90, endAngle: 180)
        // Left edge back to start.
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
            // Dismiss only if click is outside this panel.
            let loc = event.locationInWindow
            let screenLoc: NSPoint
            if let w = event.window {
                screenLoc = w.convertToScreen(NSRect(origin: loc, size: .zero)).origin
            } else {
                screenLoc = loc
            }
            if !self.frame.contains(screenLoc) {
                self.closePanel()
            }
        }
    }

    private func removeOutsideMonitor() {
        if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
    }
}
