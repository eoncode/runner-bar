import AppKit

// MARK: - PanelArrowWindow
//
// A tiny transparent child window that draws only the upward-pointing arrow caret.
// Sits above the main panel, centred under the status button.
// Kept separate so the main panel layout/sizing is never touched.
//
// ❌ NEVER merge arrow drawing into AppDelegate or PanelChromeView.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

let arrowH: CGFloat = 8
let arrowW: CGFloat = 16

final class ArrowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Match the NSVisualEffectView hudWindow material colour
        let fill: NSColor = isDark ? NSColor(white: 0.18, alpha: 0.97) : NSColor(white: 0.95, alpha: 0.97)
        let mid = bounds.width / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid, y: bounds.height))           // tip (top)
        path.addLine(to: CGPoint(x: mid - arrowW / 2, y: 0))      // base left
        path.addLine(to: CGPoint(x: mid + arrowW / 2, y: 0))      // base right
        path.closeSubpath()
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
}

final class PanelArrowWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: arrowW * 2, height: arrowH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        contentView = ArrowView(frame: NSRect(x: 0, y: 0, width: arrowW * 2, height: arrowH))
    }

    /// Position arrow so tip is centred under buttonMidX, touching panelTop.
    func reposition(buttonMidX: CGFloat, panelTop: CGFloat) {
        let x = buttonMidX - arrowW
        let y = panelTop                // base of arrow sits at top of main panel
        setFrame(NSRect(x: x, y: y, width: arrowW * 2, height: arrowH), display: true, animate: false)
    }
}
