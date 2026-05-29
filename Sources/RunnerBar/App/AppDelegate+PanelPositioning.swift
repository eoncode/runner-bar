// AppDelegate+PanelPositioning.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - AppDelegate + Panel Positioning

/// Extension responsible for panel show/hide toggle and frame positioning.
extension AppDelegate {

    // MARK: Toggle

    /// Toggles the panel: shows it if hidden, hides it if visible.
    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: Show / Hide

    /// Positions and shows the panel anchored below the status item button.
    func showPanel() {
        guard let panel, let button = statusItem?.button else { return }
        resizeAndRepositionPanel()
        panel.orderFrontRegardless()
        panelIsOpen = true
        button.highlight(true)
    }

    /// Hides the panel and removes status button highlight.
    func hidePanel() {
        guard let panel else { return }
        panel.orderOut(nil)
        panelIsOpen = false
        statusItem?.button?.highlight(false)
    }

    // MARK: Resize + Reposition

    /// Recomputes the panel frame from the hosting controller's `preferredContentSize`
    /// and repositions it below the status item button, clamped to the visible screen.
    ///
    /// Also updates the CAShapeLayer corner mask to match the new size.
    /// See docs/sheet-rectangle-corners.md — mask path must stay in sync with frame.
    func resizeAndRepositionPanel() {
        guard let panel, let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main,
              let hc = hostingController else { return }

        let preferred = hc.preferredContentSize
        guard preferred.width > 0, preferred.height > 0 else { return }

        let maxH = screen.visibleFrame.height * 0.85
        let panelH = min(preferred.height, maxH)
        let panelW = preferred.width

        // Update the CAShapeLayer mask path to match new size.
        // ❌ NEVER skip this — stale mask path = wrong corner radius at new size.
        if let mask = panel.contentView?.layer?.mask as? CAShapeLayer {
            mask.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: CGSize(width: panelW, height: panelH)),
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        let originX = buttonFrameInScreen.midX - panelW / 2
        let originY = buttonFrameInScreen.minY - panelH - arrowHeight

        let visibleFrame = screen.visibleFrame
        let clampedX = max(visibleFrame.minX + 8,
                           min(originX, visibleFrame.maxX - panelW - 8))
        let clampedY = max(visibleFrame.minY + 8, originY)

        panel.setFrame(
            NSRect(x: clampedX, y: clampedY, width: panelW, height: panelH),
            display: true,
            animate: false
        )
    }
}
