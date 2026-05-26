// AppDelegate+PanelSetup.swift
// RunnerBar
import AppKit
import Combine
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPanel construction, PanelChromeView wiring, KVO on
// preferredContentSize, and Combine subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.

/// Extension responsible for NSPanel construction, PanelChromeView wiring,
/// KVO observation, and Combine subscriptions that drive icon and store updates.
extension AppDelegate {

    // MARK: Panel construction

    /// Builds the NSPanel, embeds the SwiftUI hosting controller inside
    /// PanelChromeView, wires KVO, and starts all Combine subscriptions.
    ///
    /// When `OPEN_PANEL_ON_LAUNCH` is set (UI testing only), opens the panel
    /// directly at a hardcoded on-screen position so the AX tree can see it.
    /// ❌ NEVER call `openPanel()` from this branch — it requires a real status
    ///    item button frame which doesn't exist in a pure XCUIApplication launch.
    func setupPanel() {
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

        // Production: .popUpMenu keeps the panel above all normal windows.
        // UI testing: must use .floating so the XCTest AX server includes the
        // panel in app.windows. NSPanel at .popUpMenu level is treated as a
        // system overlay and is INVISIBLE to XCTest's AX tree, even when
        // on-screen. .floating is the highest level XCTest can query.
        // ❌ NEVER change this condition — .popUpMenu breaks AX in tests.
        if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
            newPanel.level = .floating
        } else {
            newPanel.level = .popUpMenu
        }

        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        // Pin appearance to darkAqua so the glass chrome never toggles on click.
        // ❌ NEVER remove or set to nil — causes light/dark toggling on click.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
        newPanel.appearance = NSAppearance(named: .darkAqua)
        panel = newPanel

        setupKVO(controller: controller)
        setupCombineSubscriptions()

        // Auto-open for UI tests: avoids needing a real mouse click on the
        // status item, which moves the cursor and is banned in CI.
        // ❌ NEVER use this flag outside of XCUITest scenarios.
        // ❌ NEVER call openPanel() here — it positions relative to the status
        //    item button frame which is nil/zero in a pure XCUIApplication launch,
        //    causing the panel to be placed off-screen (invisible to AX tree).
        if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let p = self.panel else { return }
                let screen = NSScreen.main ?? NSScreen.screens[0]
                // Place panel in the top-right corner of the main screen,
                // well within the visible area so AX can see it.
                let x = screen.visibleFrame.maxX - p.frame.width - 20
                let y = screen.visibleFrame.maxY - p.frame.height - 20
                p.setFrameOrigin(NSPoint(x: x, y: y))
                p.orderFront(nil)
            }
        }
    }

    // MARK: KVO

    /// Observes `preferredContentSize` on the hosting controller and triggers
    /// a panel resize whenever the SwiftUI content height changes.
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

    /// Starts all Combine subscriptions: local runner reloads, remote runner
    /// store updates (icon + observable reload), and scope mutation restarts.
    ///
    /// When `UI_TESTING` is set in the environment (i.e. launched by
    /// XCUIApplication during automated UI tests), all network polling and
    /// keychain access is skipped. This prevents macOS from showing a keychain
    /// approval dialog for every ad-hoc-signed CI build.
    private func setupCombineSubscriptions() {
        // LocalRunnerStore subscription is safe — no network or keychain access.
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        // Skip all network + keychain activity during UI tests.
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
