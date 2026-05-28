// AppDelegate.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - NSPanel architecture note
//
// ⚠️ NSPanel (Pattern 2 from #377) is used instead of NSPopover to prevent
// lateral panel jumps on content-size changes. See ARCHITECTURE.md §Panel Lifecycle.
//
// HOW THE PANEL WORKS:
// 1. Panel is a borderless, non-activating NSPanel.
// 2. Position is computed from status button's window frame (screen coords):
//      statusItemRect = button.window!.frame   ← already in screen coords
//      panelX = statusItemRect.midX - contentW/2   ← re-centred each resize
//      panelTopY = statusItemRect.minY - gap       ← locked at open time
//      y (frame origin) = max(visibleFrame.minY, panelTopY - totalH) ← clamped
//              ❌ NEVER re-derive panelTopY from statusItemRect inside
//                 resizeAndRepositionPanel() — see ARCHITECTURE.md §Panel Lifecycle.
//      panelH  = clampedContentH + arrowHeight
// 3. arrowX = statusItemRect.midX - panel.frame.minX
//    ❌ NEVER use convertToScreen(button.frame) — button.frame is button-local.
// 4. sizingOptions = .preferredContentSize: KVO on preferredContentSize
//    → resizeAndRepositionPanel() → setFrame(). Zero jump.
// 5. Dismiss: NSEvent global monitor + NSWorkspace app-switch notification.
//
// CHROME DIMENSIONS (match NSPopover exactly):
//   arrowHeight = 9pt, arrowWidth = 30pt, cornerRadius = 10pt
//
// WIDTH: Content-driven via preferredContentSize.width.
// SwiftUI views declare their own minWidth or idealWidth — NO shared fixed width.
// resizeAndRepositionPanel() clamps to [minWidth..maxWidth] and re-centres
// the panel under the status button.
//
// INITIAL WIDTH (openPanel):
// initPanelWidth is the fallback frame width used for the initial open before
// SwiftUI has measured anything. 320 is a compact default.
// ❌ NEVER set initPanelWidth > maxWidth.
// ❌ NEVER restore initPanelWidth to 600.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen mirrors panelIsOpen. Injected via wrapEnv().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// ❌ NEVER pass as a plain Bool prop to PanelMainView.
// See ARCHITECTURE.md §panelVisibilityState.

// NOTE: KeyablePanel is defined in KeyablePanel.swift (internal access level).
// It must NOT be private or fileprivate — AppDelegate+Navigation.swift accesses
// `panel: KeyablePanel?` from a separate file. See ARCHITECTURE.md §KeyablePanel.

// MARK: - AppDelegate

// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded.
/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: The properties and methods below are `internal` (not `private`) because
    // Swift `private` does not cross file boundaries. AppDelegate+Navigation.swift
    // requires read/write access to all of them. Do not widen beyond `internal`.

    /// The statusItem property.
    var statusItem: NSStatusItem?           // internal: required for AppDelegate+Navigation
    /// The panel property.
    var panel: KeyablePanel?               // internal: required for AppDelegate+Navigation
    /// The chrome property.
    var chrome: PanelChromeView?           // internal: required for AppDelegate+Navigation
    /// The hostingController property.
    var hostingController: NSHostingController<AnyView>? // internal: required for AppDelegate+Navigation
    /// The observable constant.
    let observable = RunnerViewModel()      // internal: required for AppDelegate+Navigation
    /// The savedNavState property.
    var savedNavState: NavState?           // internal: required for AppDelegate+Navigation
    /// The panelIsOpen property.
    var panelIsOpen = false                // internal: required for AppDelegate+Navigation

    /// The eventMonitor property.
    var eventMonitor: Any?                 // internal: required for AppDelegate+Navigation
    /// The sizeObservation property.
    var sizeObservation: NSKeyValueObservation?
    /// The workspaceObserver property.
    var workspaceObserver: Any?
    /// The cancellables property.
    var cancellables = Set<AnyCancellable>()

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel() — see ARCHITECTURE.md §Panel Lifecycle.
    var panelTopY: CGFloat?                // internal: required for AppDelegate+Navigation

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv(). ❌ NEVER pass as plain Bool to PanelMainView.
    /// The panelVisibilityState constant.
    let panelVisibilityState = PanelVisibilityState() // internal: required for AppDelegate+Navigation

    /// Lower bound for panel content width (clamp floor in resizeAndRepositionPanel).
    static let minWidth: CGFloat = 280

    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {       // internal: required for AppDelegate+Navigation
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The maxWidth property.
    var maxWidth: CGFloat {                // internal: required for AppDelegate+Navigation
        let screenMax = statusItemScreen.visibleFrame.width * 0.9
        return min(900, screenMax)
    }

    /// The maxHeight property.
    var maxHeight: CGFloat {               // internal: required for AppDelegate+Navigation
        statusItemScreen.visibleFrame.height * 0.85
    }

    /// The gap constant.
    static let gap: CGFloat = 2

    /// Initial panel width used before SwiftUI has measured content.
    static let initPanelWidth: CGFloat = 320

    // MARK: - Sheet guard
    //
    // SwiftUI .sheet() attaches as a child NSWindow to the panel (panel.sheets).
    // Clicks inside the sheet land outside the panel frame, which would normally
    // trigger the global mouse-down monitor and call closePanel() immediately.
    // Both dismiss paths (eventMonitor + workspaceObserver) must check this flag
    // before closing the panel.
    // ❌ NEVER remove this check from the eventMonitor or workspaceObserver blocks.
    /// Returns true when a SwiftUI sheet is currently presented over the panel.
    private var hasActiveSheet: Bool {
        guard let panel else { return false }
        return !panel.sheets.isEmpty
    }

    // MARK: - Environment injection

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState and §wrapEnv.
    // ❌ NEVER bypass. ❌ NEVER remove .environmentObject(panelVisibilityState).
    // swiftlint:disable:next missing_docs
    func wrapEnv<V: View>(_ view: V) -> AnyView { // internal: required for AppDelegate+Navigation
        AnyView(view.environmentObject(panelVisibilityState))
    }

    // MARK: - App lifecycle

    /// Called before applicationDidFinishLaunching.
    /// Sets activation policy to .regular during UI tests so XCTest can see
    /// all windows and elements in the AX tree — LSUIElement apps run as
    /// .runningBackground and their windows are invisible to XCTest by default.
    /// Must be in applicationWillFinishLaunching (not DidFinish) so the policy
    /// is set before XCTest's automation session handshake completes.
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

    // MARK: - OAuth URL callback (#326)
    //
    // Handles the runnerbar://oauth/callback?code=... redirect from GitHub.
    // Searches the full urls array — see ARCHITECTURE.md §OAuth URL handling.

    /// Performs the application operation.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Panel resize

    // Regression guard — see ARCHITECTURE.md §Panel Lifecycle.
    // ❌ NEVER re-derive panelTopY here. ❌ NEVER call from a background thread.
    //
    // UI_TESTING note: in UI tests button.window is nil (no real menu-bar backing
    // window). The guard below falls back to a centred rect on the main screen so
    // the panel is positioned on-screen and XCTest's AX server can find it in
    // app.windows. ❌ NEVER remove the button.window fallback.
    // swiftlint:disable:next missing_docs
    func resizeAndRepositionPanel() { // internal: required for AppDelegate+Navigation
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let topY = panelTopY else { return }

        let preferred = hostingController?.preferredContentSize ?? CGSize(width: Self.initPanelWidth, height: 300)

        let contentW = min(max(preferred.width, Self.minWidth), maxWidth)
        let contentH = min(max(preferred.height, 60), maxHeight)
        let totalH = contentH + arrowHeight

        // In UI tests button.window is nil — fall back to centred position on main screen.
        // ❌ NEVER remove this fallback — required for testPanelOpensAndShowsWorkflowsSection.
        let statusItemRect: NSRect
        if let windowFrame = button.window?.frame {
            statusItemRect = windowFrame
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let sf = screen.visibleFrame
            statusItemRect = NSRect(
                x: sf.midX - contentW / 2,
                y: sf.maxY,
                width: contentW,
                height: 0
            )
        }

        let posX = statusItemRect.midX - contentW / 2
        let rawPosY = topY - totalH
        let screenMinY = statusItemScreen.visibleFrame.minY
        let posY = max(rawPosY, screenMinY)

        panel.setFrame(NSRect(x: posX, y: posY, width: contentW, height: totalH),
                       display: true, animate: false)

        chrome.arrowX = statusItemRect.midX - panel.frame.minX
    }

    // MARK: - Navigation

    // Regression guard — see ARCHITECTURE.md §Panel Lifecycle.
    // ❌ NEVER remove the resizeAndRepositionPanel() call from this method.
    // swiftlint:disable:next missing_docs
    func navigate(to view: AnyView) { // internal: required for AppDelegate+Navigation
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input

    // See KeyablePanel.swift for the full explanation.
    // ❌ NEVER call this for views that have no text input (main, step log).
    /// Performs the makeKeyForTextInput operation.
    func makeKeyForTextInput() { // internal: required for AppDelegate+Navigation
        panel?.wantsKey = true
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dismiss

    /// Performs the closePanel operation.
    func closePanel() {
        guard panelIsOpen else { return }
        panel?.wantsKey = false
        panel?.orderOut(nil)
        panelIsOpen = false
        panelTopY = nil
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        // Nav-state persistence — see ARCHITECTURE.md §Nav-state persistence.
        // ❌ NEVER replace hostingController?.rootView = mainView() with a no-op stub.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let preserved = self.savedNavState
            self.hostingController?.rootView = self.mainView()
            self.savedNavState = preserved
        }
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

    // internal (not private) so AppDelegate+StatusItem.swift can reference
    // it via #selector(togglePanel) from a separate file.
    /// Performs the togglePanel operation.
    @objc func togglePanel() {
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open

    /// Performs the openPanel operation.
    ///
    /// When `UI_TESTING=1` is set, `button.window` is nil because the app runs
    /// as `.regular` activation policy (no real menu-bar backing window). In that
    /// case we fall back to a centred position on the main screen.
    ///
    /// Panel window level is handled once in setupPanel() — .floating for UI
    /// tests, .popUpMenu for production. Do not set panel.level here.
    ///
    /// The global NSEvent monitor and NSWorkspace app-switch observer are skipped
    /// during UI tests: XCTest synthesises mouse events as global NSEvents, which
    /// the monitor misinterprets as outside-clicks, immediately calling closePanel()
    /// before the click reaches its target inside the panel.
    /// ❌ NEVER install the event monitor or workspace observer when UI_TESTING is set.
    func openPanel() {
        guard let button = statusItem?.button, let panel else { return }

        // In UI tests button.window is nil (no real menu-bar backing window), so
        // we fall back to a centred rect on the main screen.
        let statusItemRect: NSRect
        if let windowFrame = button.window?.frame {
            statusItemRect = windowFrame
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let sf = screen.visibleFrame
            statusItemRect = NSRect(
                x: sf.midX - Self.initPanelWidth / 2,
                y: sf.maxY,
                width: Self.initPanelWidth,
                height: 0
            )
        }

        log("AppDelegate › openPanel — seeding observable: actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) localRunners=\(LocalRunnerStore.shared.runners.count)")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

        panelIsOpen = true
        panelVisibilityState.isOpen = true
        panelTopY = statusItemRect.minY - Self.gap

        let initW = Self.initPanelWidth
        let initH: CGFloat = 300 + arrowHeight
        let posX = statusItemRect.midX - initW / 2
        let posY = statusItemRect.minY - initH - Self.gap

        panel.setFrame(
            NSRect(x: posX, y: posY, width: initW, height: initH),
            display: false, animate: false
        )

        chrome?.arrowX = statusItemRect.midX - posX
        // Use wantsKey + makeKeyAndOrderFront to guarantee the panel receives
        // keyboard events on first open, preventing grey cold-open regression.
        // ❌ NEVER revert to orderFront(nil) — grey cold-open regression (#892).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        panel.wantsKey = true
        panel.makeKeyAndOrderFront(nil)
        resizeAndRepositionPanel()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        // Skip dismiss monitors during UI tests.
        // XCTest synthetic global mouse events are misread as outside-clicks by the
        // monitor, causing closePanel() to fire before the click reaches its target.
        // ❌ NEVER install these monitors when UI_TESTING is set.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            // ❌ NEVER remove the hasActiveSheet guard — sheets attach as child
            // windows; clicks inside them land outside the panel frame and would
            // otherwise trigger a spurious closePanel().
            guard !self.hasActiveSheet else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            if !panel.frame.contains(screenLoc) { self.closePanel() }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // ❌ NEVER remove the hasActiveSheet guard — switching apps while a
            // sheet is open (e.g. browser OAuth redirect) must not close the panel.
            guard !self.hasActiveSheet else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                Task { @MainActor [weak self] in self?.closePanel() }
            }
        }
    }
}
