// AppDelegate.swift
// RunnerBar

import AppKit
import SwiftUI

// MARK: - NSPopover architecture note
//
// ⚠️ NSPopover is used instead of NSPanel as of fix/#1017.
//
// WHY NSPopover instead of NSPanel:
// NSPanel with custom CAShapeLayer masking or cornerRadius+masksToBounds
// loses its rounded corners whenever a SwiftUI .sheet is presented as a
// child NSWindow. AppKit's sheet attachment path modifies the parent
// window's CALayer tree, discarding any mask or masksToBounds we set.
// NSPopover uses NSPopoverWindowFrame, a dedicated window class whose chrome
// is drawn by the window-server compositor — completely unaffected by sheet
// attachment. Rounded corners survive .sheet natively.
//
// HOW THE POPOVER WORKS:
// 1. NSPopover with animates=false, behavior=.applicationDefined.
// 2. Shown via popover.show(relativeTo: button.bounds, of: button,
//    preferredEdge: .minY) — anchors to the status bar button once on open.
//    The arrow anchor is determined by positioningRect+view at show() time
//    and is NOT moved when contentSize is updated later.
// 3. Size is driven by KVO on NSHostingController.preferredContentSize.
//    Both width AND height are updated via popover.contentSize.
//    ⚠️ Do NOT call popover.show() again on resize — that re-anchors and jumps.
//    Updating contentSize alone resizes in place with the arrow fixed.
// 4. Width is clamped to [minWidth..maxWidth] from screen bounds.
// 5. Dismiss: popover.performClose(nil) driven by the global NSEvent monitor
//    (outside clicks) and NSWorkspace app-switch notification.
//    See openPanel() for the monitor implementation.
//    See docs/graveyard.md for history of attempted alternatives.
//
// ARROW VISIBILITY (#1184):
// The NSPopover anchor arrow visibility is controlled by the `shouldHideAnchor`
// private KVC key, applied immediately before each `popover.show()` call.
// This is NOT App Store safe but RunnerBar is not App Store distributed.
// The preference is stored in AppPreferencesStore.showPopoverArrow (default: true).
// ⚠️ The arrow state is baked in at show() time — changing the pref takes
//    effect on the NEXT open. Never call show() mid-session to apply it.
// ⚠️ The KVC call is guarded by responds(to:) so the app degrades silently
//    (arrow stays visible) rather than crashing if Apple removes the key.
//
// TEXT INPUT:
// NSPopover windows are key-capable natively. NSApp.activate() is
// sufficient to allow TextFields to receive first-responder.
//
// LATERAL JUMP PREVENTION:
// Only update contentSize — never re-call popover.show() on resize.
// Updating contentSize repositions the popover body but keeps the arrow
// anchored to the original positioningRect on the status bar button.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is set in openPanel()/closePanel()/hidePanel().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// See ARCHITECTURE.md §panelVisibilityState.
//
// SHEET STATE ACROSS HIDE/SHOW:
// When the user taps outside while a sheet is open, hidePanel() is called.
// Goal: re-opening the status bar icon should show settings WITH the sheet.
//
// How this works:
// - hidePanel() does NOT call dismissSheets() and does NOT reset rootView.
//   NSPopover's performClose() closes the NSPopoverWindowFrame and all its
//   child windows (including the sheet NSWindow) together. They are removed
//   from screen but the NSHostingController and its SwiftUI tree remain alive.
//   SwiftUI @State (editingRunner, showAddScopeSheet, etc.) is preserved inside
//   the hosting controller's view because the hosting controller itself is never
//   destroyed or replaced.
// - On re-open, openPanel() calls popover.show() which re-attaches the same
//   NSHostingController. SwiftUI sees the existing state, the binding is still
//   true, and re-presents the sheet automatically.
//
// closePanel() IS different: it is called when the user explicitly closes
// (e.g. pressing Escape, or navigating back). In that case we DO reset rootView
// to mainView() so the next open starts fresh at the main view.
//
// ❌ NEVER add dismissSheets() to hidePanel() — it destroys sheet @State.
// ❌ NEVER reset hostingController.rootView inside hidePanel().
// ❌ NEVER add a validatedView(for: .settings) navigate() call inside openPanel()
//    when the current rootView is already SettingsView — it replaces the live
//    view with a new struct and resets all @State.

// MARK: - AppDelegate
// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.
/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // NOTE: Properties are `internal` (not `private`) because Swift `private`
    // does not cross file boundaries. AppDelegate+Navigation.swift requires
    // read/write access to all of them.

    /// The NSStatusItem anchoring the menu-bar icon and popover.
    var statusItem: NSStatusItem?
    /// The NSPopover that hosts the SwiftUI panel (replaces the old KeyablePanel/NSPanel approach).
    var popover: NSPopover?
    /// The SwiftUI hosting controller embedded inside `popover`. Its `rootView` is
    /// swapped on navigation; the controller itself is never recreated.
    var hostingController: NSHostingController<AnyView>?
    /// The owned observable view-model passed into every SwiftUI view via the environment.
    /// `RunnerStore` and `LocalRunnerStore` push updates into this instance via `await MainActor.run { }`.
    let observable = RunnerViewModel()
    /// Owned `LocalRunnerStore` actor — injected with `observable` so all state
    /// pushes land in the view model that SwiftUI actually observes.
    ///
    /// `lazy var` is required: `LocalRunnerStore.shared` is only valid after
    /// `LocalRunnerStore.configure(viewModel:)` is called in
    /// `applicationDidFinishLaunching`. A `let` default would be evaluated
    /// eagerly during `AppDelegate.init()` — before `configure()` runs —
    /// triggering the `fatalError` guard inside `LocalRunnerStore.shared`.
    lazy var localRunnerStore: LocalRunnerStore = .shared
    /// Owned `RunnerStore` actor.
    ///
    /// ⚠️ This property has no lazy default body. The sole init site is
    /// `AppDelegate+PanelSetup.swift` → `setupCombineSubscriptions()`, which
    /// runs on the `@MainActor` and can therefore pass `AppPreferencesStore.shared`
    /// and `ScopeStore.shared` as explicit arguments. Never add a `lazy var` body
    /// here — doing so creates a dual-init path: if anything reads `runnerStore`
    /// before `setupCombineSubscriptions()` runs, a second `RunnerStore` instance
    /// with live observation tasks would be created and then silently replaced,
    /// causing a brief window with two competing poll loops.
    var runnerStore: RunnerStore!
    /// The last nav destination the user was on before the popover was closed or hidden.
    /// Restored by `openPanel()` so the user lands back where they left off.
    var savedNavState: NavState?
    /// Sheet state that must survive transient popover hides.
    let panelSheetState = PanelSheetState()
    /// Retained handle for the sign-out observation task started in
    /// `setupSignOutSubscription()` (AppDelegate+Polling.swift).
    /// Keeping a strong reference ensures the task is never silently abandoned.
    var signOutTask: Task<Void, Never>?
    /// Mirrors `popover.isShown`. Kept separately because `NSPopover.isShown` is not
    /// reliable immediately after `performClose` — our flag is the source of truth.
    /// Set to `true` by `openPanel()`, set to `false` by `tearDownOpenState()`.
    var panelIsOpen = false
    /// Set to `true` by `hidePopoverWindowsPreservingSheets()` when the popover window
    /// is hidden without closing, so the sheet NSWindow survives.
    /// ❌ NEVER read outside hidePopoverWindowsPreservingSheets / restorePopoverWindowsPreservingSheetsIfNeeded / closePanel()
    var preservedSheetWindowHide = false
    /// KVO observation token for `NSHostingController.preferredContentSize`.
    /// Drives popover resize without re-calling `popover.show()`.
    var sizeObservation: NSKeyValueObservation?
    /// Global NSEvent monitor installed by `openPanel()` to hide the popover on
    /// outside clicks. Removed by `tearDownOpenState()`.
    var outsideClickMonitor: Any?
    /// NSWorkspace observer installed by `openPanel()` to hide the popover when
    /// another app is activated. Removed by `tearDownOpenState()`.
    var workspaceObserver: NSObjectProtocol?
    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    /// Maximum popover content width (90% of screen).
    var maxWidth: CGFloat { min(900, statusItemScreen.visibleFrame.width * 0.9) }
    /// Maximum popover height (85% of visible screen).
    var maxHeight: CGFloat { statusItemScreen.visibleFrame.height * 0.85 }
    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Sheet guard

    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    var hasActiveSheet: Bool {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return false }
        return !popoverWindow.sheets.isEmpty
    }

    // MARK: - Environment injection

    /// Wraps a SwiftUI view in the shared environment objects required by the panel.
    /// Every view produced by a view-factory in AppDelegate+Navigation.swift must
    /// pass through this helper.
    /// ❌ NEVER remove `panelVisibilityState` from the environment injection here.
    /// `PanelContainerView` and its dim overlay observe this object;
    /// removing it causes a runtime crash on sheet dismissal.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environment(panelVisibilityState))
    }

    // MARK: - Popover resize

    /// Clamps the popover's `contentSize` to the current screen bounds.
    /// Called after every rootView swap and from the KVO size observer.
    /// ⚠️ Never call `popover.show()` here — updating `contentSize` resizes in place
    /// without re-anchoring the arrow.
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            popover.contentSize = NSSize(width: newW, height: newH)
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view` and immediately
    /// recalculates the popover size. The popover arrow stays pinned.
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    /// Calling directly from a SwiftUI view creates a retain cycle via the
    /// closure capture and bypasses the actor-safe callback path.
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismiss

    /// Shared teardown called by every close/hide path.
    /// Resets `panelIsOpen` and the visibility state flag.
    /// Internal (not private) — called cross-file from AppDelegate+PanelSetup.swift.
    /// ⚠️ Must be called on the main actor. AppDelegate is @MainActor;
    ///    do not call from background threads or completion handlers.
    /// Does NOT reset `savedNavState` — callers that want a full close (not a hide)
    ///    must nil it out themselves (see `closePanel()`).
    /// Does NOT reset `panelVisibilityState.isTransientHide` — that flag is cleared
    ///    by `openPanel()` on re-open.
    /// Note: the `Thread.callStackSymbols` log line below is wrapped in `#if DEBUG`
    ///       and compiles away completely in release builds.
    @MainActor
    func tearDownOpenState() {
        #if DEBUG
        log("AppDelegate › tearDownOpenState — caller=\(Thread.callStackSymbols[1])")
        #endif
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
            log("AppDelegate › tearDownOpenState — outsideClickMonitor removed")
        } else {
            log("AppDelegate › tearDownOpenState — outsideClickMonitor was already nil")
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
            log("AppDelegate › tearDownOpenState — workspaceObserver removed")
        } else {
            log("AppDelegate › tearDownOpenState — workspaceObserver was already nil")
        }
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets rootView to main so next open starts fresh.
    /// ❌ Do NOT call this from outside-tap / workspace-switch — use hidePanel().
    func closePanel() {
        log("AppDelegate › closePanel — panelIsOpen=\(panelIsOpen)")
        guard panelIsOpen else {
            log("AppDelegate › closePanel — guard exit: not open")
            return
        }
        popover?.performClose(nil)
        preservedSheetWindowHide = false
        tearDownOpenState()
        savedNavState = nil
        panelSheetState.clearRunnerSheet()
        hostingController?.rootView = mainView()
    }

    /// Hides the popover on outside-tap or workspace app-switch.
    ///
    /// Called directly by `outsideClickMonitor` and `workspaceObserver` (both installed in `openPanel()`).
    /// Intentionally does NOT call dismissSheets() and does NOT reset rootView.
    /// The NSHostingController and its SwiftUI @State (including any open sheet
    /// bindings) remain alive. On re-open, popover.show() reattaches the same
    /// controller and SwiftUI re-presents the sheet automatically.
    ///
    /// ❌ NEVER add dismissSheets() here.
    /// ❌ NEVER reset hostingController.rootView here.
    /// Note: the `Thread.callStackSymbols` log line below is wrapped in `#if DEBUG`
    ///       and compiles away completely in release builds.
    func hidePanel() {
        #if DEBUG
        log("AppDelegate › hidePanel — ENTER panelIsOpen=\(panelIsOpen) hasActiveSheet=\(hasActiveSheet) preservedSheetWindowHide=\(preservedSheetWindowHide) popoverBehavior=\(popover?.behavior.rawValue ?? -1) caller=\(Thread.callStackSymbols[1])")
        #endif
        guard panelIsOpen else {
            log("AppDelegate › hidePanel — guard exit: not open")
            return
        }
        panelSheetState.captureTransientHideState()
        // ❌ Set isTransientHide = true BEFORE isOpen = false.
        // PanelContainerView.onChange fires synchronously when isOpen changes.
        // If isTransientHide is not already true at that point, onChange will
        // incorrectly clear isSheetActive, causing the dim-overlay animation to
        // replay on the next restore even though the sheet never closed.
        // See PanelVisibilityState.isTransientHide for the full lifecycle.
        panelVisibilityState.isTransientHide = true
        if hidePopoverWindowsPreservingSheets() {
            tearDownOpenState()
            return
        }
        popover?.performClose(nil)
        tearDownOpenState()
    }

    /// Orders the popover and attached sheet windows out without closing them.
    ///
    /// Closing an NSPopover while an attached SwiftUI sheet is open can detach
    /// the visible sheet while leaving the parent content in AppKit's disabled
    /// sheet-modal state. Ordering the existing windows out preserves the live
    /// sheet session so re-opening can order the same windows back in.
    @discardableResult
    func hidePopoverWindowsPreservingSheets() -> Bool {
        log("AppDelegate › hidePopoverWindowsPreservingSheets — ENTER hasActiveSheet=\(hasActiveSheet) popoverWindow=\(String(describing: popover?.contentViewController?.view.window))")
        guard hasActiveSheet,
              let popoverWindow = popover?.contentViewController?.view.window else {
            log("AppDelegate › hidePopoverWindowsPreservingSheets — guard fail (hasActiveSheet=\(hasActiveSheet) popoverWindow=\(String(describing: popover?.contentViewController?.view.window))), returning false")
            return false
        }
        log("AppDelegate › hidePopoverWindowsPreservingSheets — ordering out popoverWindow=\(popoverWindow) sheets=\(popoverWindow.sheets.count)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderOut(nil)
        }
        preservedSheetWindowHide = true
        log("AppDelegate › hidePopoverWindowsPreservingSheets — done, preservedSheetWindowHide=true")
        return true
    }

    /// Restores windows hidden by `hidePopoverWindowsPreservingSheets()`.
    @discardableResult
    func restorePopoverWindowsPreservingSheetsIfNeeded() -> Bool {
        guard preservedSheetWindowHide,
              let popoverWindow = popover?.contentViewController?.view.window else { return false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderFront(nil)
        }
        preservedSheetWindowHide = false
        return true
    }

    /// Makes the lazy NSPopover backing window key immediately after show/restore.
    ///
    /// The native Liquid Glass chrome resolves differently while the popover
    /// window is inactive. A user click makes the window key and restores the
    /// desired dark glass look; doing it immediately avoids the grey first-open
    /// state without adding tint, overlays, or extra `show()` calls.
    func makePopoverWindowKeyIfPossible() {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKey()
    }

    // MARK: - Toggle

    /// Toggles the popover: opens it if closed, closes it if open.
    /// Called by the NSStatusItem button action.
    @objc func togglePanel() {
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    /// ⚠️ show() is called ONCE per open. Resize is done via contentSize only.
    func openPanel() {
        guard let button = statusItem?.button, let popover else { return }
        log("AppDelegate › openPanel — LocalRunnerStore pushes state on every cycle, no seed needed")
        panelIsOpen = true
        panelVisibilityState.isOpen = true
        if !restorePopoverWindowsPreservingSheetsIfNeeded() {
            // Apply arrow visibility preference (#1184).
            // shouldHideAnchor is a private KVC key — not App Store safe, but
            // RunnerBar is not App Store distributed so this is acceptable.
            // ⚠️ Must be set immediately before show() — the value is latched at show() time.
            // ⚠️ Guarded by responds(to:) so the app degrades silently (arrow stays
            //    visible) rather than crashing if Apple removes the key on a future macOS.
            let hideArrow = !AppPreferencesStore.shared.showPopoverArrow
            if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
                popover.setValue(hideArrow, forKey: "shouldHideAnchor")
            }
            // Re-assert behavior and delegate immediately before show().
            // NSPopover latches these values at show() time — setting them
            // only at setupPanel() is not sufficient; AppKit can reset them
            // between calls. Without this, behavior silently falls back to
            // .transient and our outsideClickMonitor / popoverShouldClose
            // code never runs.
            popover.behavior = .applicationDefined
            popover.delegate = self
            log("AppDelegate › openPanel — PRE-SHOW behavior=\(popover.behavior.rawValue) delegate=\(String(describing: popover.delegate))")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            log("AppDelegate › openPanel — POST-SHOW behavior=\(popover.behavior.rawValue)")
        }
        makePopoverWindowKeyIfPossible()
        resizeAndRepositionPanel()
        // Only navigate if we have a saved state AND the current rootView is
        // NOT already showing that view (i.e. we came from closePanel/mainView reset,
        // not from hidePanel which preserves rootView).
        // Simpler approach: only navigate when savedNavState is set AND
        // hasActiveSheet is false (if sheet is open, rootView is correct already).
        if let saved = savedNavState, !hasActiveSheet, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }
        // Install outside-click monitor. Fires on every left/right click outside
        // the popover. tearDownOpenState() removes the monitor on every close path.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: event.locationInWindow, size: .zero)
            ).origin ?? NSEvent.mouseLocation
            log("AppDelegate › outsideClickMonitor — FIRED type=\(event.type.rawValue) screenLoc=\(screenLoc)")
            Task { @MainActor [weak self] in
                guard let self else {
                    log("AppDelegate › outsideClickMonitor — self is nil, skipping")
                    return
                }
                log("AppDelegate › outsideClickMonitor — panelIsOpen=\(self.panelIsOpen)")
                guard self.panelIsOpen else {
                    log("AppDelegate › outsideClickMonitor — guard exit: panel not open")
                    return
                }
                guard !self.hasActiveSheet else {
                    log("AppDelegate › outsideClickMonitor — guard exit: hasActiveSheet=true, skipping hidePanel")
                    return
                }
                guard let popoverWindow = self.popover?.contentViewController?.view.window else {
                    log("AppDelegate › outsideClickMonitor — WARNING: popoverWindow is nil, skipping hidePanel")
                    return
                }
                log("AppDelegate › outsideClickMonitor — popoverFrame=\(popoverWindow.frame) screenLoc=\(screenLoc) contains=\(popoverWindow.frame.contains(screenLoc))")
                if popoverWindow.frame.contains(screenLoc) {
                    log("AppDelegate › outsideClickMonitor — click inside popover window, ignoring")
                    return
                }
                log("AppDelegate › outsideClickMonitor — calling hidePanel() screenLoc=\(screenLoc)")
                self.hidePanel()
            }
        }
        log("AppDelegate › openPanel — outsideClickMonitor installed: \(String(describing: outsideClickMonitor))")
        // Install app-switch observer. Fires when any app becomes frontmost,
        // including RunnerBar itself.
        //
        // IMPORTANT — self-activation guard is intentional:
        // `guard activatedApp != NSRunningApplication.current` prevents the
        // popover from self-dismissing when RunnerBar regains focus after an
        // NSOpenPanel picker closes (the picker re-activates its parent app,
        // which would otherwise trigger hidePanel on the way back in).
        // Do NOT remove this guard.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                log("AppDelegate › workspaceObserver — FIRED but activatedApp is nil, skipping")
                return
            }
            let appName = activatedApp.localizedName ?? "unknown"
            log("AppDelegate › workspaceObserver — FIRED activated=\(appName)")
            guard activatedApp != NSRunningApplication.current else {
                log("AppDelegate › workspaceObserver — guard exit: RunnerBar self-activated, skipping hidePanel")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    log("AppDelegate › workspaceObserver — self is nil, skipping")
                    return
                }
                log("AppDelegate › workspaceObserver — panelIsOpen=\(self.panelIsOpen)")
                guard self.panelIsOpen else {
                    log("AppDelegate › workspaceObserver — guard exit: panel not open")
                    return
                }
                guard !self.hasActiveSheet else {
                    log("AppDelegate › workspaceObserver — guard exit: hasActiveSheet=true, skipping hidePanel")
                    return
                }
                log("AppDelegate › workspaceObserver — calling hidePanel() because activated=\(appName) panelIsOpen=\(self.panelIsOpen)")
                self.hidePanel()
            }
        }
        log("AppDelegate › openPanel — workspaceObserver installed")
    }
}
