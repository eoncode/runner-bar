// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and Combine
// subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// WHY NSPopover (#1017):
// NSPopover uses NSPopoverWindowFrame whose chrome is drawn by the
// window-server compositor. Rounded corners survive SwiftUI .sheet
// attachment natively — no CALayer manipulation required or desired.
//
// SHEET HANDLING:
// SwiftUI .sheet() attaches as a child NSWindow to the popover's backing
// window. Two problems arise:
//
// 1. NO DIM: NSPopoverWindowFrame does not participate in AppKit's standard
//    modal sheet dimming. Fix: we apply a SwiftUI .overlay dim inside the
//    popover content via PanelContainerView, keyed on hasActiveSheet.
//
// 2. ORPHANED SHEET on outside click: even with .applicationDefined behavior,
//    AppKit can close the popover when the user clicks outside (e.g. via the
//    NSPopoverDelegate popoverShouldClose path). If the popover closes while a
//    sheet is open, the sheet's NSWindow is orphaned — visible but with no
//    parent popover, leaving the app in a non-interactive frozen state.
//    Fix: NSPopoverDelegate.popoverShouldClose returns false when a sheet is
//    open. This prevents AppKit from closing the popover underneath a sheet.
//
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. Updating contentSize resizes
// the popover in-place — the arrow stays pinned to the original
// positioningRect. ❌ NEVER call popover.show() again on resize.

/// Extension responsible for NSPopover construction, KVO, and Combine subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and Combine subscriptions.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: NSPopoverDelegate

    /// Prevents the popover closing while a sheet is presented over it.
    /// Without this, AppKit orphans the sheet's NSWindow and the app freezes.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Block close if a sheet is currently attached.
        // The user must dismiss the sheet first.
        return !hasActiveSheet
    }

    /// Called after the popover actually closes (e.g. user pressed Escape).
    /// Ensures our internal state stays in sync.
    public func popoverDidClose(_ notification: Notification) {
        guard panelIsOpen else { return }
        // Force-dismiss any orphaned sheet windows just in case.
        popover?.contentViewController?.view.window?.sheets.forEach { sheet in
            popover?.contentViewController?.view.window?.endSheet(sheet)
        }
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.resizeAndRepositionPanel() }
        }
    }

    // MARK: Combine subscriptions

    /// Starts all Combine subscriptions.
    private func setupCombineSubscriptions() {
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate › didUpdate fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.start()

        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate › ScopeStore.didMutate — restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)
    }
}
