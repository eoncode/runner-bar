import AppKit
import Combine
import SwiftUI

// MARK: - NSPanel architecture note
//
// ⚠️ ARCHITECTURE: NSPanel (Pattern 2 from #377) — READ BEFORE CHANGING.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// WHY NSPanel INSTEAD OF NSPopover:
// NSPopover re-anchors by AppKit design on ANY contentSize change while shown.
// This is not a bug — it is documented intentional behavior. Every attempt to
// dynamically resize NSPopover while visible causes a side-jump. Confirmed across:
//   • #377, #375, #376, #52, #53, #54, #57, #321, #370
//   • Just10/MEMORY.md (identical bug history)
//   • Stack Overflow #14449945, #69877522
// NSPanel has no anchor concept. setFrame() while visible = zero jump, ever.
//
// HOW THE PANEL WORKS:
// 1. Panel is a borderless, non-activating NSPanel.
// 2. Position is computed from status button's window frame (screen coords):
//      statusItemRect = button.window!.frame   ← already in screen coords
//      panelX = statusItemRect.midX - contentW/2   ← re-centred each resize
//      panelTopY = statusItemRect.minY - gap       ← locked at open time
//      y (frame origin) = max(visibleFrame.minY, panelTopY - totalH) ← clamped
//              ❌ NEVER re-derive panelTopY from statusItemRect inside
//                 resizeAndRepositionPanel() — menu bar hide/show shifts
//                 statusItemRect.minY, moving the panel under the notch.
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
// POPOVEROPENSTATE:
// popoverOpenState.isOpen mirrors panelIsOpen. Injected via wrapEnv().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// ❌ NEVER pass as a plain Bool prop to PopoverMainView.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

// NOTE: KeyablePanel is defined in KeyablePanel.swift (internal access level).
// It must NOT be private or fileprivate — AppDelegate+Navigation.swift accesses
// `panel: KeyablePanel?` from a separate file.

// MARK: - AppDelegate

// ⚠️ @MainActor ISOLATION CONTRACT — DO NOT REMOVE THIS ANNOTATION.
// AppDelegate runs entirely on the main thread. @MainActor gives the Swift 6
// compiler static proof of this so every method and stored property is verified
// as main-thread-only without any runtime assertion.
//
// The nonisolated blocking helper (enrichStepsIfNeeded) lives in
// AppDelegate+Navigation.swift and is intentionally exempt — it performs
// blocking network I/O and is always dispatched onto DispatchQueue.global().
//
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: The properties and methods below are `internal` (not `private`) because
    // Swift `private` does not cross file boundaries. AppDelegate+Navigation.swift
    // requires read/write access to all of them. Do not widen beyond `internal`.

    var statusItem: NSStatusItem?           // internal: required for AppDelegate+Navigation
    var panel: KeyablePanel?               // internal: required for AppDelegate+Navigation
    var chrome: PanelChromeView?           // internal: required for AppDelegate+Navigation
    var hostingController: NSHostingController<AnyView>? // internal: required for AppDelegate+Navigation
    let observable = RunnerStoreObservable() // internal: required for AppDelegate+Navigation
    var savedNavState: NavState?           // internal: required for AppDelegate+Navigation
    var panelIsOpen = false                // internal: required for AppDelegate+Navigation

    var eventMonitor: Any?                 // internal: required for AppDelegate+Navigation
    var sizeObservation: NSKeyValueObservation?
    var workspaceObserver: Any?
    var cancellables = Set<AnyCancellable>()

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel().
    var panelTopY: CGFloat?                // internal: required for AppDelegate+Navigation

    // ⚠️ REGRESSION GUARD (ref #377):
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as a plain Bool prop to PopoverMainView.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    let popoverOpenState = PopoverOpenState() // internal: required for AppDelegate+Navigation

    /// Lower bound for panel content width (clamp floor in resizeAndRepositionPanel).
    static let minWidth: CGFloat = 280

    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {       // internal: required for AppDelegate+Navigation
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    var maxWidth: CGFloat {                // internal: required for AppDelegate+Navigation
        let screenMax = statusItemScreen.visibleFrame.width * 0.9
        return min(900, screenMax)
    }

    var maxHeight: CGFloat {               // internal: required for AppDelegate+Navigation
        statusItemScreen.visibleFrame.height * 0.85
    }

    static let gap: CGFloat = 2

    /// Initial panel width used before SwiftUI has measured content.
    static let initPanelWidth: CGFloat = 320

    // MARK: - Environment injection

    /// ❌ NEVER bypass. ❌ NEVER remove .environmentObject(popoverOpenState).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    /// ALLOWED UNDER ANY CIRCUMSTANCE.
    func wrapEnv<V: View>(_ view: V) -> AnyView { // internal: required for AppDelegate+Navigation
        AnyView(view.environmentObject(popoverOpenState))
    }

    // MARK: - Status icon helpers

    private func menuBarImage(for status: AggregateStatus) -> NSImage {
        NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            ?? NSImage()
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = menuBarImage(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
        chromeView.addSubview(controller.view)
        chrome = chromeView

        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = chromeView
        newPanel.isOpaque = false
        newPanel.backgroundColor = NSColor(white: 1, alpha: 0.001)
        newPanel.hasShadow = true
        newPanel.level = .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        panel = newPanel

        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { self?.resizeAndRepositionPanel() }
        }

        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onChange fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
            self.updateStatusIcon()
            self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
        }
        RunnerStore.shared.start()
    }

    // MARK: - OAuth URL callback (#326)
    //
    // Handles the runnerbar://oauth/callback?code=... redirect from GitHub after
    // the user authorizes the app in the browser. Forwards to OAuthService which
    // exchanges the code for a token and saves it to Keychain.
    //
    // OAuthService.onCompletion is wired in SettingsView so the Account section
    // updates automatically once the token arrives.
    //
    // Search the full urls array for the OAuth callback rather than assuming
    // urls.first — macOS may deliver multiple URLs and the callback may not be
    // first, which would leave the sign-in spinner stuck. (#597)

    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Status icon

    /// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
    /// ❌ NEVER read RunnerStore.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists; use menuBarImage(for:).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func updateStatusIcon() {
        statusItem?.button?.image = menuBarImage(for: RunnerStore.shared.aggregateStatus)
    }

    // MARK: - Panel resize

    /// ❌ NEVER re-derive panelTopY here.
    /// ❌ NEVER call from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression is major major major.
    func resizeAndRepositionPanel() { // internal: required for AppDelegate+Navigation
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let topY = panelTopY else { return }

        let preferred = hostingController?.preferredContentSize ?? CGSize(width: Self.initPanelWidth, height: 300)

        let contentW = min(max(preferred.width, Self.minWidth), maxWidth)
        let contentH = min(max(preferred.height, 60), maxHeight)
        let totalH = contentH + arrowHeight

        let posX = statusItemRect.midX - contentW / 2
        let rawPosY = topY - totalH
        let screenMinY = statusItemScreen.visibleFrame.minY
        let posY = max(rawPosY, screenMinY)

        panel.setFrame(NSRect(x: posX, y: posY, width: contentW, height: totalH),
                       display: true, animate: false)

        chrome.arrowX = statusItemRect.midX - panel.frame.minX
    }

    // MARK: - Navigation

    /// ❌ NEVER remove the resizeAndRepositionPanel() call from this method.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    func navigate(to view: AnyView) { // internal: required for AppDelegate+Navigation
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input

    // See KeyablePanel.swift for the full explanation.
    // ❌ NEVER call this for views that have no text input (main, step log).
    func makeKeyForTextInput() { // internal: required for AppDelegate+Navigation
        panel?.wantsKey = true
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dismiss

    func closePanel() {
        guard panelIsOpen else { return }
        panel?.wantsKey = false
        panel?.orderOut(nil)
        panelIsOpen = false
        panelTopY = nil
        popoverOpenState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        // ⚠️ NAV STATE PERSISTENCE (#385) — DO NOT REMOVE THIS COMMENT.
        // Capture savedNavState before calling mainView() (which resets it),
        // then restore it so openPanel()'s validatedView path works.
        // ❌ NEVER replace this with a no-op stub PopoverMainView.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let preserved = self.savedNavState
            self.hostingController?.rootView = self.mainView()
            self.savedNavState = preserved
        }
    }

    func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    // MARK: - Toggle

    @objc private func togglePanel() {
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open

    func openPanel() {
        guard let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let panel else { return }

        log("AppDelegate › openPanel — seeding observable: actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) localRunners=\(LocalRunnerStore.shared.runners.count)")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

        panelIsOpen = true
        popoverOpenState.isOpen = true
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
        panel.orderFront(nil)
        resizeAndRepositionPanel()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }
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
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                Task { @MainActor [weak self] in self?.closePanel() }
            }
        }
    }
}
