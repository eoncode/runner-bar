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
        log("AppDelegate › setupPanel — begin")
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
        log("AppDelegate › setupPanel — popover created, wiring KVO + Combine")

        setupKVO(controller: controller)
        setupCombineSubscriptions()
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    /// Always allow close. Outside-tap during a sheet hides the popover so the
    /// user can interact with other apps. Nav state is preserved and restored
    /// on next open via savedNavState.
    public func popoverShouldClose(_ _: NSPopover) -> Bool {
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    /// Primary purpose: safety net for OS-initiated closes (e.g. user clicks outside).
    /// When `closePanel()` or `hidePanel()` drives the close, they call
    /// `tearDownOpenState()` directly — by the time this fires, `panelIsOpen`
    /// is already `false` and the guard exits immediately.
    public func popoverDidClose(_ _: Notification) {
        log("AppDelegate › popoverDidClose — panelIsOpen=\(panelIsOpen)")
        guard panelIsOpen else {
            log("AppDelegate › popoverDidClose — guard exit (panelIsOpen already false)")
            return
        }
        tearDownOpenState()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        log("AppDelegate › setupKVO — attaching preferredContentSize observer")
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            // KVO can fire on a background thread — hop to main before touching UI.
            DispatchQueue.main.async { [weak self] in self?.resizeAndRepositionPanel() }
        }
    }

    // MARK: Combine subscriptions

    /// Starts all Combine subscriptions.
    private func setupCombineSubscriptions() {
        log("AppDelegate › setupCombineSubscriptions — begin")

        // $runners — local runner list changed on disk (added/removed runner config).
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runners in
                guard let self else { return }
                log("AppDelegate › LocalRunnerStore.$runners fired — count=\(runners.count)")
                self.observable.reload()
            }
            .store(in: &cancellables)

        // Everything below makes live network calls — skip entirely in UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppDelegate › setupCombineSubscriptions — UI_TESTING detected, skipping network setup")
            return
        }

        // didUpdate — API poll cycle complete; refresh icon and view-model.
        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate › didUpdate fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload()
            }
            .store(in: &cancellables)

        // FIX (#1179): Seed localRunners BEFORE starting the poll loop.
        // LocalRunnerStore.init() only calls loadIndex() which populates
        // runnerIndex (name→path map) but leaves runners=[] until refresh()
        // runs the disk-hydration + launchctl + GitHub-enrichment pipeline.
        // Without this call, RunnerStore.buildInstallPathMap always receives
        // localRunners=[] → installPathMap is always empty → busy runners
        // never get their installPath → metrics are never fetched.
        log("AppDelegate › setupCombineSubscriptions — triggering LocalRunnerStore.refresh() BEFORE starting poll loop")
        LocalRunnerStore.shared.refresh()

        // Start the polling loop. Guarded above — never runs during UI tests.
        log("AppDelegate › setupCombineSubscriptions — starting RunnerStore poll loop")
        RunnerStore.shared.start()

        // didMutate — scope changed; must restart the store entirely so it polls
        // the correct repos from the beginning.
        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate › ScopeStore.didMutate — restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)

        log("AppDelegate › setupCombineSubscriptions — complete")
    }
}
