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
//    modal sheet dimming. Fix: PanelContainerView polls NSWindow.sheets and
//    overlays Color.black.opacity(0.35) when a sheet is present.
//
// 2. OUTSIDE-TAP BEHAVIOUR DURING SHEET:
//    Desired: tapping outside while a sheet is open hides the popover
//    (so the user can interact with other apps), but saves nav state so
//    re-opening the status bar app restores the sheet context.
//
//    Implementation:
//    - popoverShouldClose always returns true. AppKit is never blocked.
//    - popoverDidClose saves hasActiveSheet into a flag before state clears.
//    - openPanel restores via savedNavState (already the case).
//    - The global event monitor no longer has a hasActiveSheet guard —
//      outside clicks always trigger closePanel().
//    - closePanel() does NOT call endSheet on any open sheet. The sheet
//      window is a child of the popover window; when the popover window
//      closes, AppKit removes all child windows including the sheet.
//      On re-open, SwiftUI re-presents the sheet if the binding is still true
//      (e.g. showAddScopeSheet = true is preserved in @State in SettingsView).
//      savedNavState = .settings ensures we navigate back to SettingsView.
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

    /// Always allow close. Outside-tap during a sheet hides the popover so the
    /// user can interact with other apps. Nav state is preserved and restored
    /// on next open via savedNavState.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    public func popoverDidClose(_ notification: Notification) {
        guard panelIsOpen else { return }
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
                self.observable.reload()
            }
            .store(in: &cancellables)

        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate › didUpdate fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload()
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
