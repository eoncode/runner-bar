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
// SHEET ORPHAN PREVENTION — read before touching closePanel() or hidePanel():
// When NSPopover.performClose() fires while a SwiftUI .sheet is presented,
// the sheet's NSWindow (a child of the popover window) is NOT automatically
// removed by AppKit. It becomes an orphan: visible, blocking hit-testing, with
// no SwiftUI tree driving it. The app appears frozen.
//
// FIX: Before calling performClose(), call endSheet on every attached sheet
// window. This lets AppKit clean them up synchronously before the popover
// closes. Do this in BOTH closePanel() and hidePanel().
//
// ❌ NEVER remove the dismissSheets() call from closePanel() or hidePanel().
// ❌ NEVER try to preserve sheet @State across close/open — SwiftUI @State
//    lives inside the View value type and is reset when a new view is created.
//    Creating a new SettingsView() always gives fresh @State = sheet gone.
//    The only correct behaviour on re-open is: navigate to settings (no sheet),
//    which is at least interactive. Sheet cannot be restored.

// MARK: - AppDelegate

// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded.
/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: Properties are `internal` (not `private`) because Swift `private`
    // does not cross file boundaries. AppDelegate+Navigation.swift requires
    // read/write access to all of them.

    /// The statusItem property.
    var statusItem: NSStatusItem?
    /// The popover replacing the old KeyablePanel.
    var popover: NSPopover?
    /// The hostingController property.
    var hostingController: NSHostingController<AnyView>?
    /// The observable constant.
    let observable = RunnerViewModel()
    /// The savedNavState property.
    var savedNavState: NavState?
    /// Mirrors popover.isShown — kept for compatibility with navigation code.
    var panelIsOpen = false

    /// The eventMonitor property.
    var eventMonitor: Any?
    /// The sizeObservation property.
    var sizeObservation: NSKeyValueObservation?
    /// The workspaceObserver property.
    var workspaceObserver: Any?
    /// The cancellables property.
    var cancellables = Set<AnyCancellable>()

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// The panelVisibilityState constant.
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
    // NOTE: internal (not private) — accessible from AppDelegate+PanelSetup.swift.
    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    var hasActiveSheet: Bool {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return false }
        return !popoverWindow.sheets.isEmpty
    }

    // MARK: - Environment injection

    // swiftlint:disable:next missing_docs
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(panelVisibilityState))
    }

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Performs the applicationDidFinishLaunching operation.
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureGHAPI(
            { endpoint in ghAPI(endpoint) },
            isRateLimited: { ghIsRateLimited }
        )
        setupStatusItem()
        setupPanel()
    }

    // MARK: - OAuth URL callback

    /// Performs the application operation.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Popover resize

    // ⚠️ Only updates contentSize — never calls popover.show() again.
    // Updating contentSize resizes the popover in place; the arrow stays
    // anchored to the original positioningRect. Calling show() again would
    // re-anchor and cause a lateral jump.
    // swiftlint:disable:next missing_docs
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        // Only update if size actually changed to avoid redundant layout passes.
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            popover.contentSize = NSSize(width: newW, height: newH)
        }
    }

    // MARK: - Navigation

    // swiftlint:disable:next missing_docs
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Sheet orphan cleanup

    /// Ends all sheets currently attached to the popover window.
    ///
    /// MUST be called before performClose() in both closePanel() and hidePanel().
    /// Without this, sheet NSWindows become orphaned when the popover closes:
    /// they remain visible and block all hit-testing, freezing the app.
    ///
    /// ❌ NEVER remove this call from closePanel() or hidePanel().
    private func dismissSheets() {
        guard let win = popover?.contentViewController?.view.window else { return }
        for sheet in win.sheets {
            win.endSheet(sheet)
        }
    }

    // MARK: - Dismiss

    /// Closes the popover. Dismisses any open sheets first to prevent orphan
    /// NSWindows from blocking hit-testing after the popover closes.
    func closePanel() {
        guard panelIsOpen else { return }
        // ❌ NEVER remove dismissSheets() — orphaned sheet windows freeze the app.
        dismissSheets()
        popover?.performClose(nil)
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        // Reset rootView to main. savedNavState=.settings is preserved so
        // openPanel() navigates back to SettingsView on re-open.
        // ⚠️ Sheet @State (showAddScopeSheet etc.) is NOT preserved — SwiftUI
        // @State lives in the View value type and is reset when a new view is
        // created. The sheet will be gone on re-open; SettingsView will be
        // interactive. This is intentional — see ARCHITECTURE.md §SheetOrphans.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    /// Hides the popover (workspace app-switch). Dismisses sheets first.
    func hidePanel() {
        guard panelIsOpen else { return }
        // ❌ NEVER remove dismissSheets() — orphaned sheet windows freeze the app.
        dismissSheets()
        popover?.performClose(nil)
        panelIsOpen = false
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
    }

    /// Performs the removeEventMonitor operation.
    func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    /// Performs the removeWorkspaceObserver operation.
    func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    // MARK: - Toggle

    /// Performs the togglePanel operation.
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

        log("AppDelegate › openPanel — seeding observable: actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) localRunners=\(LocalRunnerStore.shared.runners.count)")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

        panelIsOpen = true
        panelVisibilityState.isOpen = true

        // Show the popover. The arrow anchors to button.bounds here and
        // is never moved again — subsequent contentSize changes resize
        // the body but keep the arrow pinned.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Activate so TextFields can receive input immediately.
        NSApp.activate(ignoringOtherApps: true)

        // Update to actual SwiftUI content size after show.
        resizeAndRepositionPanel()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        // Skip dismiss monitors during UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        // Outside-click always closes — no hasActiveSheet guard.
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
                self.closePanel()
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
