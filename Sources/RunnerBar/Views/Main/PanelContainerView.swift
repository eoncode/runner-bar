// PanelContainerView.swift
// RunnerBar
import SwiftUI

// MARK: - PanelContainerView
//
// Thin wrapper around the real panel content that adds a sheet-dim overlay.
//
// WHY THIS EXISTS (#1017 — NSPopover sheet dim):
// NSPopoverWindowFrame (the backing window of NSPopover) does not participate
// in AppKit's standard modal sheet dimming path. When a SwiftUI .sheet is
// presented, the parent popover content is NOT dimmed by the system.
//
// FIX: We observe the hosting NSWindow.sheets via a Timer-based poll (the only
// reliable way without subclassing NSWindow) and overlay a semi-transparent
// black rectangle when sheets are present. The observed window is captured from
// this view hierarchy, not from NSApp.windows, so stale hidden popover windows
// cannot leave an invisible click-blocking overlay behind after a transient hide.
//
// ❌ NEVER remove the overlay — without it the popover content is fully
//    interactive behind an open sheet, which is confusing and buggy.
// ❌ NEVER use GeometryReader here — it fights NSPopover's sizing.

/// Wraps popover content and dims it when a SwiftUI sheet is active.
struct PanelContainerView<Content: View>: View {
    /// The child view to wrap.
    let content: Content
    /// Whether a sheet is currently active over the popover.
    @State private var isSheetActive = false
    /// The NSWindow hosting this view hierarchy.
    @State private var hostWindow: NSWindow?
    /// Timer used to poll NSWindow.sheets.
    @State private var pollTimer: Timer?
    /// Tracks panel open/close state to start and stop polling.
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState

    /// The body property.
    var body: some View {
        ZStack {
            content
            WindowReader(window: $hostWindow)
                .frame(width: 0, height: 0)
            if isSheetActive {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isSheetActive)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open {
                // ❌ Do NOT reset isSheetActive here — a transient hide keeps the
                // sheet window alive. Resetting causes a flicker: the overlay
                // disappears for one frame then the 100ms timer brings it back.
                startPolling()
            } else {
                stopPolling()
                // Safe to clear on close — closePanel() has already called
                // dismissSheets() so no sheet window remains.
                isSheetActive = false
            }
        }
    }

    // MARK: - Sheet detection
    //
    // NSWindow.sheets is the authoritative source. We poll it because
    // there is no KVO-observable property or notification for sheet attachment
    // on NSPopoverWindowFrame without subclassing.
    /// Starts a repeating timer to poll NSWindow.sheets.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let window = hostWindow else { return }
                // If the popover window is hidden (transient hide / app-switch),
                // do NOT touch isSheetActive — the sheet window is still attached
                // and state must survive intact for when the window is restored.
                // ❌ Never set isSheetActive = false here on !isVisible.
                guard panelVisibilityState.isOpen, window.isVisible else { return }

                let hasVisibleSheet = window.sheets.contains { $0.isVisible }
                if hasVisibleSheet != isSheetActive { isSheetActive = hasVisibleSheet }
            }
        }
    }

    /// Stops and invalidates the polling timer.
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

/// Reports the NSWindow that hosts this SwiftUI view hierarchy.
private struct WindowReader: NSViewRepresentable {
    /// Binding updated with the host NSWindow.
    @Binding var window: NSWindow?

    /// Creates the underlying NSView and reports its window.
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { window = view.window }
        return view
    }

    /// Updates the window binding when the view's window changes.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { window = nsView.window }
    }
}
