// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and
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
// POPOVER BEHAVIOR: .applicationDefined (#1195)
// behavior = .applicationDefined is set at setupPanel() AND re-asserted
// immediately before every popover.show() call in openPanel(). AppKit latches
// the behavior at show-time; failing to re-assert it caused silent reversion
// to .transient between sessions (Attempt 8 root cause).
//
// .transient was tried (Attempt 2) and failed — AppKit's .transient dismiss
// fires on ANY outside interaction, including clicks inside NSOpenPanel.
// .transient does NOT have special awareness of system panels.
//
// OUTSIDE-CLICK / APP-SWITCH HIDE (#1195 — what actually works):
// Both are handled by a manual NSEvent global monitor (outsideClickMonitor)
// and an NSWorkspace observer (workspaceObserver), both installed by openPanel()
// and torn down by tearDownOpenState().
//
// The key guard in outsideClickMonitor is:
//
//   guard !self.hasActiveSheet else { return }   // ← THE FIX
//
// NSOpenPanel is attached to the popover window via beginSheetModal(for:),
// making it appear in popoverWindow.sheets. While any sheet is attached,
// hasActiveSheet is true and every outside click is ignored — the popover
// cannot be dismissed by a click that lands inside the NSOpenPanel.
//
// popoverShouldClose always returns true — AppKit is never blocked here.
// All dismiss control goes through the manual monitor.
//
// ❌ NEVER use picker.begin { } (free-floating NSOpenPanel). It does NOT
//    appear in popoverWindow.sheets and the hasActiveSheet guard is blind to it.
// ❌ NEVER use runModal() for NSOpenPanel. Same reason as above.
// ✅ ALWAYS use picker.beginSheetModal(for: popoverWindow) so the picker
//    attaches as a child sheet and hasActiveSheet fires correctly.
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
//    Tapping outside while a sheet is open hides the popover so the user
//    can interact with other apps, but savedNavState preserves where they
//    were so re-opening restores context.
//
//    Implementation:
//    - popoverShouldClose always returns true. AppKit is never blocked.
//    - popoverDidClose saves hasActiveSheet state before state clears.
//    - openPanel restores via savedNavState.
//    - Sheet NSWindows are children of the popover window; AppKit removes
//      them when the popover closes. SwiftUI re-presents on re-open if the
//      binding is still true. savedNavState = .settings ensures navigation.
//
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. Updating contentSize resizes
// the popover in-place — the arrow stays pinned to the original
// positioningRect. ❌ NEVER call popover.show() again on resize.

/// Extension responsible for NSPopover construction, KVO, and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and async subscriptions.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        // .applicationDefined: popoverShouldClose(_:) is consulted on every
        // is true, keeping the popover alive when user clicks in NSOpenPanel.
        // Manual NSEvent monitor + NSWorkspace observer handle hide-on-app-switch.
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — popover created, wiring KVO + subscriptions")

        setupKVO(controller: controller)
        setupSubscriptions()
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    /// Always returns `true` — AppKit is never blocked from closing the popover here.
    ///
    /// All dismiss control is handled by the manual `outsideClickMonitor` and
    /// `workspaceObserver` in `openPanel()`. Those monitors guard against
    /// NSOpenPanel clicks via `hasActiveSheet` (the panel is attached as a sheet
    /// via `beginSheetModal`, so `popoverWindow.sheets` is non-empty while it
    /// is open). There is no need to block AppKit here.
    ///
    /// `isFilePickerActive` is intentionally NOT used here. Earlier attempts
    /// (Attempts 4–6, see `docs/graveyard.md`) tried gating this method on a
    /// boolean flag, but `beginSheetModal` makes that unnecessary: the sheet
    /// attachment is structural truth visible via `popoverWindow.sheets`, which
    /// `hasActiveSheet` reads directly. The flag approach was removed in favour
    /// of that structural check.
    ///
    /// See the OUTSIDE-CLICK / APP-SWITCH HIDE comment block above for the full
    /// mechanism. See `docs/graveyard.md` for the history of approaches that
    /// tried to gate this method and why they all failed.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        #if DEBUG
        log("AppDelegate › popoverShouldClose — CALLED behavior=\(popover.behavior.rawValue) panelIsOpen=\(panelIsOpen) caller=\(Thread.callStackSymbols[1])")
        #endif
        log("AppDelegate › popoverShouldClose — returning true (allowing close)")
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    /// Primary purpose: safety net for OS-initiated closes (e.g. user clicks outside).
    /// When `closePanel()` or `hidePanel()` drives the close, they call
    /// `tearDownOpenState()` directly — by the time this fires, `panelIsOpen`
    /// is already `false` and the guard exits immediately.
    public func popoverDidClose(_ notification: Notification) {
        #if DEBUG
        log("AppDelegate › popoverDidClose — panelIsOpen=\(panelIsOpen) behavior=\((NSApp.delegate as? AppDelegate)?.popover?.behavior.rawValue ?? -1) stack=\(Thread.callStackSymbols.prefix(5).joined(separator: "||"))")
        #endif
        guard panelIsOpen else {
            log("AppDelegate › popoverDidClose — guard exit (panelIsOpen already false)")
            return
        }
        log("AppDelegate › popoverDidClose — calling tearDownOpenState (unexpected OS-driven close)")
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

    // MARK: Async subscriptions

    /// Wires all long-lived async subscriptions (sign-out listener, startup sequence).
    private func setupSubscriptions() {
        log("AppDelegate › setupSubscriptions — begin")

        // local runner list changes are now pushed directly from LocalRunnerStore
        // into observable.localRunners via await MainActor.run — no Combine sink needed.

        // Everything below makes live network calls — skip entirely in UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppDelegate › setupSubscriptions — UI_TESTING detected, skipping network setup")
            return
        }

        // Wire LocalRunnerStore.shared to this AppDelegate's RunnerViewModel instance.
        //
        // ⚠️ Must be called before the startup Task below (and before any other
        // LocalRunnerStore.shared access). LocalRunnerStore no longer self-initialises
        // with RunnerViewModel.shared — that singleton was a different object from
        // AppDelegate.observable and caused localRunners to push into a view model
        // that no SwiftUI view observed (permanent empty local-runner list).
        //
        // ❌ NEVER move this call inside the Task — AppDelegate.localRunnerStore
        //    is a computed `lazy var` backed by `LocalRunnerStore.shared`. The first
        //    access to `localRunnerStore` (inside the Task) must find the instance
        //    already configured, or it fatalErrors.
        LocalRunnerStore.configure(viewModel: observable)
        log("AppDelegate › setupSubscriptions — LocalRunnerStore.configure(viewModel:) called")

        // NOTE: The `RunnerStore.didUpdate` Combine sink has been removed.
        // `RunnerStore` is now a Swift actor that pushes state directly to
        // the injected `viewModel` (AppDelegate.observable) via `await MainActor.run { }`
        // at the end of every fetch cycle, and calls `AppDelegate.updateStatusIcon()` inside
        // that same `MainActor.run` block — so icon refresh is still driven once
        // per completed fetch cycle without any Combine subscription.
        // ℹ️ `RunnerViewModel.shared` is a fatalError accessor — the live instance
        // is AppDelegate.observable, injected explicitly into both stores.

        // RunnerStore.init no longer accepts @MainActor-isolated default values
        // (Swift 6: default values for parameters must not be @MainActor-isolated
        // in a nonisolated context). AppPreferencesStore.shared and ScopeStore.shared
        // are therefore passed explicitly here, where we are already on the @MainActor.
        runnerStore = RunnerStore(
            viewModel: observable,
            localRunnerStore: localRunnerStore,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            onStatusUpdate: { [weak self] in self?.updateStatusIcon() }
        )
        log("AppDelegate › setupSubscriptions — RunnerStore created with injected stores")

        // RunnerStore.init no longer accepts @MainActor-isolated default values
        // (Swift 6: default values for parameters must not be @MainActor-isolated
        // in a nonisolated context). AppPreferencesStore.shared and ScopeStore.shared
        // are therefore passed explicitly here, where we are already on the @MainActor.
        runnerStore = RunnerStore(
            viewModel: observable,
            localRunnerStore: localRunnerStore,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            onStatusUpdate: { [weak self] in self?.updateStatusIcon() }
        )
        log("AppDelegate › setupCombineSubscriptions — RunnerStore created with injected stores")

        // RunnerStore.init no longer accepts @MainActor-isolated default values
        // (Swift 6: default values for parameters must not be @MainActor-isolated
        // in a nonisolated context). AppPreferencesStore.shared and ScopeStore.shared
        // are therefore passed explicitly here, where we are already on the @MainActor.
        runnerStore = RunnerStore(
            viewModel: observable,
            localRunnerStore: localRunnerStore,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            onStatusUpdate: { [weak self] in self?.updateStatusIcon() }
        )
        log("AppDelegate › setupCombineSubscriptions — RunnerStore created with injected stores")

        // FIX: Await LocalRunnerStore.refreshAsync() before starting the poll loop.
        //
        // refresh() (fire-and-forget) spawns a Task and returns immediately.
        // start() fires fetch() on the very next runloop turn — before refresh()'s
        // Task has a chance to run, because both are @MainActor and start() is called
        // synchronously. Result: localRunners=[] on cycle 1, installPathMap empty,
        // metrics missing on first runner appearance.
        //
        // refreshAsync() suspends until disk hydration + launchctl + GitHub enrichment
        // completes, then start() fires. Cycle 1 always has a populated installPathMap
        // so runner rows appear with CPU/MEM already set.
        log("AppDelegate › setupSubscriptions — scheduling async startup sequence")
        Task { [weak self] in
            guard let self else { return }
            log("AppDelegate › startup — awaiting localRunnerStore.refreshAsync()")
            await self.localRunnerStore.refreshAsync()
            log("AppDelegate › startup — refreshAsync() complete, starting runnerStore poll loop")
            await self.runnerStore.start()
            log("AppDelegate › startup — runnerStore poll loop started")
        }

        // Scope changes (add / remove / enable toggle) restart RunnerStore so it polls
        // the correct repos from the beginning. RunnerStore observes
        // ScopeStore.activeScopes internally via withObservationTracking/AsyncStream,
        // so no Combine sink is needed here — the actor's own observer handles it.
        log("AppDelegate › setupSubscriptions — complete")
    }
}
