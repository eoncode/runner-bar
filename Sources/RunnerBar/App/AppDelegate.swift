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
// swiftlint:disable:next missing_docs
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NOTE: The properties and methods below are `internal` (not `private`) because
    // Swift `private` does not cross file boundaries. AppDelegate+Navigation.swift
    // requires read/write access to all of them. Do not widen beyond `internal`.
    // swiftlint:disable missing_docs
    var statusItem: NSStatusItem?
    var panel: KeyablePanel?
    var chrome: PanelChromeView?
    var hostingController: NSHostingController<AnyView>?
    let observable = RunnerViewModel()
    var savedNavState: NavState?
    var panelIsOpen = false
    var eventMonitor: Any?
    var sizeObservation: NSKeyValueObservation?
    var workspaceObserver: Any?
    var cancellables = Set<AnyCancellable>()
    var panelTopY: CGFloat?
    let panelVisibilityState = PanelVisibilityState()
    static let minWidth: CGFloat = 280
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var maxWidth: CGFloat {
        let screenMax = statusItemScreen.visibleFrame.width * 0.9
        return min(900, screenMax)
    }
    var maxHeight: CGFloat {
        statusItemScreen.visibleFrame.height * 0.85
    }
    static let gap: CGFloat = 2
    static let initPanelWidth: CGFloat = 320
    // swiftlint:enable missing_docs

    // MARK: - Environment injection
    // swiftlint:disable:next missing_docs
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(panelVisibilityState))
    }

    // MARK: - App lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
    }

    // MARK: - OAuth URL callback (#326)
    //
    // Handles the runnerbar://oauth/callback?code=... redirect from GitHub.
    // Searches the full urls array — see ARCHITECTURE.md §OAuth URL handling.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "runnerbar" && $0.host == "oauth" })
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Panel resize
    // ❌ NEVER re-derive panelTopY here. ❌ NEVER call from a background thread.
    // swiftlint:disable:next missing_docs
    func resizeAndRepositionPanel() {
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
    // swiftlint:disable:next missing_docs
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Make key for text input
    // swiftlint:disable:next missing_docs
    func makeKeyForTextInput() {
        panel?.wantsKey = true
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dismiss
    // swiftlint:disable:next missing_docs
    func closePanel() {
        guard panelIsOpen else { return }
        panel?.wantsKey = false
        panel?.orderOut(nil)
        panelIsOpen = false
        panelTopY = nil
        panelVisibilityState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let preserved = self.savedNavState
            self.hostingController?.rootView = self.mainView()
            self.savedNavState = preserved
        }
    }

    // swiftlint:disable:next missing_docs
    func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    // swiftlint:disable:next missing_docs
    func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    // MARK: - Toggle
    // swiftlint:disable:next missing_docs
    @objc func togglePanel() {
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open
    // swiftlint:disable:next missing_docs
    func openPanel() {
        guard let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let panel else { return }

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
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                Task { @MainActor [weak self] in self?.closePanel() }
            }
        }
    }
}
