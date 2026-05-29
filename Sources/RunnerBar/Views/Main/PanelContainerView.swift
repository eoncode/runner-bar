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
// FIX: We observe popoverWindow.sheets via a Timer-based poll (the only
// reliable way without subclassing NSWindow) and overlay a semi-transparent
// black rectangle when sheets are present. This exactly matches what the
// system sheet dimming looks like on NSPanel.
//
// ❌ NEVER remove the overlay — without it the popover content is fully
//    interactive behind an open sheet, which is confusing and buggy.
// ❌ NEVER use GeometryReader here — it fights NSPopover's sizing.
// ❌ NEVER use .allowsHitTesting(false) on the overlay — it must block
//    interaction with the dimmed content below.

/// Wraps popover content and dims it when a SwiftUI sheet is active.
struct PanelContainerView<Content: View>: View {
    let content: Content
    @State private var isSheetActive = false
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState

    var body: some View {
        ZStack {
            content
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
            if open { startPolling() } else { stopPolling(); isSheetActive = false }
        }
    }

    // MARK: - Sheet detection
    //
    // NSWindow.sheets is the authoritative source. We poll it because
    // there is no KVO-observable property or notification for sheet attachment
    // on NSPopoverWindowFrame without subclassing.
    private var pollTimer: Timer? { nil } // stored via class wrapper below
    @State private var _timer: Timer?

    private func startPolling() {
        stopPolling()
        _timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let window = NSApp.windows.first { $0.className.contains("NSPopover") }
                let hasSheets = !(window?.sheets.isEmpty ?? true)
                if hasSheets != isSheetActive { isSheetActive = hasSheets }
            }
        }
    }

    private func stopPolling() {
        _timer?.invalidate()
        _timer = nil
    }
}
