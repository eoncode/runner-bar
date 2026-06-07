// AppDelegate.swift
// RunnerBar
import AppKit
import Combine
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
// 5. Dismiss: popover.performClose(nil) or NSEvent global monitor
//    + NSWorkspace app-switch notification (same as before).
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
    /// The shared observable view-model passed into every SwiftUI view via the environment.
    let observable = RunnerViewModel()
    /// The last nav destination the user was on before the popover was closed or hidden.
    /// Restored by `openPanel()` so the user lands back where they left off.
    var savedNavState: NavState?
    /// Sheet state that must survive transient popover hides.
    let panelSheetState = PanelSheetState()
    /// Mirrors `popover.isShown`. Kept separately because `NSPopover.isShown` is not
    /// reliable immediately after `performClose` — our flag is the source of truth.
    /// Set to `true` by `openPanel()`, set to `false` by `tearDownOpenState()`.
    var panelIsOpen = false
    /// Set to `true` by `hidePopoverWindowsPreservingSheets()` when the popover window
    /// is hidden without closing, so the sheet NSWindow survives.
    /// ❌ NEVER read outside hidePopoverWindowsPreservingSheets / restorePopoverWindowsPreservingSheetsIfNeeded / closePanel()
    var preservedSheetWindowHide = false

    /// Opaque token returned by `NSEvent.addGlobalMonitorForEvents`.
    /// Typed `Any?` because that is what AppKit returns — `removeMonitor(_:)` also takes `Any`.
    var eventMonitor: Any?
    /// KVO observation token for `NSHostingController.preferredContentSize`.
    /// Drives popover resize without re-calling `popover.show()`.
    var sizeObservation: NSKeyValueObservation?
    /// Observer token returned by `NSWorkspace.notificationCenter.addObserver(forName:…)`.
    /// Typed `NSObjectProtocol?` to match the API's actual return type.
    var workspaceObserver: NSObjectProtocol?
    /// Combine cancellable bag for all long-lived subscriptions wired in `setupCombineSubscriptions()`.
    var cancellables = Set<AnyCancellable>()

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280

    /// Maximum popover content width (90% of screen).
    var maxWidth: CGFloat {
        min(900, statusItemScreen.visibleFrame.width * 0.9)
    }

    /// Maximum popover height (85% of visible screen).
    var maxHeight: CGFloat {
        statusItemScreen.visibleFrame.height * 0.85
    }

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
    ///    `PanelContainerView` and its dim overlay observe this object;
    ///    removing it causes a runtime crash on sheet dismissal.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(panelVisibilityState))
    }

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Configures the GitHub API clients, builds the
    /// status-bar item, and constructs the NSPopover panel.
    func applicationDidFinishLaunching(_ _: Notification) {
        configureGHAPI(
            { endpoint in await ghAPI(endpoint) },
            isRateLimited: { ghIsRateLimited }
        )
        configureGHRaw { endpoint in urlSessionRaw(endpoint) }
        setupStatusItem()
        setupPanel()
        setupSignOutSubscription()
    }

    // MARK: - Sign-out subscription

    /// Restarts the poll loop when the user signs out of OAuth so that
    /// `githubToken()` re-resolves to `GH_TOKEN` / `GITHUB_TOKEN` env vars
    /// on the very next fetch cycle.
    ///
    /// ## Why this lives here and not in SettingsView
    /// `SettingsView`'s `signOutCancellable` is stored in `@State` and is
    /// only alive while Settings is visible. `AppDelegate` is a true singleton
    /// for the app's lifetime, so this subscription is always active.
    ///
    /// ## What was broken (regression from PR #1138)
    /// Before #1138, polling was driven by `Timer + scheduleTimer()`. After
    /// sign-out the timer fired, `fetch()` ran, `githubToken()` found the
    /// cache cleared, and naturally fell through to env-var tokens.
    /// #1138 replaced the timer with a `pollTask: Task` that loops on
    /// `Task.sleep` — it never calls `start()` again, so the token fallback
    /// only works if `start()` is explicitly invoked after sign-out.
    private func setupSignOutSubscription() {
        OAuthService.shared.didSignOut
            .receive(on: DispatchQueue.main)
            .sink {
                log("AppDelegate › didSignOut — restarting poll loop for env-token fallback")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)
    }

    // MARK: - OAuth URL callback

    /// Handles the OAuth callback URL (`runnerbar://oauth/…`) delivered by the OS
    /// after the user authorises the GitHub OAuth flow in the browser.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            $0.scheme == GitHubConstants.oauthScheme && $0.host == GitHubConstants.oauthHost
        }) else { return }
        OAuthService.shared.handleCallback(url)
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
    ///    Calling directly from a SwiftUI view creates a retain cycle via the
    ///    closure capture and bypasses the actor-safe callback path.
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
    /// Resets `panelIsOpen`, the visibility state flag, and removes both monitors.
    /// Extracted to eliminate the duplicated 4-line block that existed in
    /// `closePanel()`, `hidePanel()`, and `popoverDidClose()`.
    /// Internal (not private) — called cross-file from AppDelegate+PanelSetup.swift.
    /// ⚠️ Must be called on the main actor. AppDelegate is @MainActor;
    ///    do not call from background threads or completion handlers.
    /// Does NOT reset `savedNavState` — callers that want a full close (not a hide)
    ///    must nil it out themselves (see `closePanel()`).
    /// Does NOT reset `panelVisibilityState.isTransientHide` — that flag is cleared
    ///    by `openPanel()` on re-open.
    @MainActor func tearDownOpenState() {
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets rootView to main so next open starts fresh.
    /// ❌ Do NOT call this from outside-tap / workspace-switch — use hidePanel().
    func closePanel() {
        guard panelIsOpen else { return }
        popover?.performClose(nil)
        preservedSheetWindowHide = false
        tearDownOpenState()
        savedNavState = nil
        panelSheetState.clearRunnerSheet()
        hostingController?.rootView = mainView()
    }

    /// Hides the popover on outside-tap or workspace app-switch.
    ///
    /// Intentionally does NOT call dismissSheets() and does NOT reset rootView.
    /// The NSHostingController and its SwiftUI @State (including any open sheet
    /// bindings) remain alive. On re-open, popover.show() reattaches the same
    /// controller and SwiftUI re-presents the sheet automatically.
    ///
    /// ❌ NEVER add dismissSheets() here.
    /// ❌ NEVER reset hostingController.rootView here.
    func hidePanel() {
        guard panelIsOpen else { return }
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
        guard hasActiveSheet,
              let popoverWindow = popover?.contentViewController?.view.window
        else { return false }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderOut(nil)
        }
        preservedSheetWindowHide = true
        return true
    }

    /// Restores windows hidden by `hidePopoverWindowsPreservingSheets()`.
    @discardableResult
    func restorePopoverWindowsPreservingSheetsIfNeeded() -> Bool {
        guard preservedSheetWindowHide,
              let popoverWindow = popover?.contentViewController?.view.window
        else { return false }

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

    /// Nil-safe teardown for the global mouse-event monitor.
    /// Safe to call when `eventMonitor` is already nil.
    func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    /// Nil-safe teardown for the workspace app-switch observer.
    /// Safe to call when `workspaceObserver` is already nil.
    func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    // MARK: - Toggle

    /// Toggles the popover: opens it if closed, closes it if open.
    /// Called by the NSStatusItem button action.
    @objc func togglePanel() {
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    /// ⚠️ show() is called ONCE per open. Resize is done via contentSize only.
    func openPanel() {
        guard let button = statusItem?.button, let popover else { return }

        log("AppDelegate › openPanel — seeding observable")
        observable.reload()

        panelIsOpen = true
        panelVisibilityState.isOpen = true

        if !restorePopoverWindowsPreservingSheetsIfNeeded() {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        makePopoverWindowKeyIfPossible()
        resizeAndRepositionPanel()

        // Only navigate if we have a saved state AND the current rootView is
        // NOT already showing that view (i.e. we came from closePanel/mainView reset,
        // not from hidePanel which preserves rootView).
        // We detect "already correct" by checking savedNavState against the
        // current rootView identity via a flag set in navigate(to:).
        // Simpler approach: only navigate when savedNavState is set AND
        // hasActiveSheet is false (if sheet is open, rootView is correct already).
        if let saved = savedNavState, !hasActiveSheet,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }

        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.popover else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            guard let popoverWindow = popover.contentViewController?.view.window else { return }
            let sheetWindows = popoverWindow.sheets
            let inSheet = sheetWindows.contains { $0.frame.contains(screenLoc) }
            if !popoverWindow.frame.contains(screenLoc) && !inSheet {
                self.hidePanel()
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                Task { @MainActor [weak self] in self?.hidePanel() }
            }
        }
    }
}
