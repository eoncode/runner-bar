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
//
// HOSTING VIEW LIFECYCLE (fix #891):
// The hosting controller view is NOT added to chromeView in setupPanel().
// It is added lazily in openPanel(), AFTER panel.orderFront(nil), so that
// viewDidMoveToWindow fires in a live on-screen window with real desktop
// pixels behind it. NSGlassEffectView then gets a valid compositor sample
// on the very first frame instead of sampling grey off-screen emptiness.
// ❌ NEVER move chromeView.addSubview(hostingController.view) back into setupPanel().
// ❌ NEVER add the hosting view before orderFront.

/// AppDelegate extension that builds the NSPanel, embeds the SwiftUI hosting controller,
/// wires KVO on `preferredContentSize`, and starts all Combine subscriptions.
extension AppDelegate {

    // MARK: Panel construction

    /// Builds the NSPanel and PanelChromeView. Does NOT add the hosting view yet —
    /// that happens lazily in openPanel() after orderFront so NSGlassEffectView
    /// gets a valid compositor sample on first show.
    func setupPanel() {
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = .clear
        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
        // ❌ NEVER add controller.view here — see HOSTING VIEW LIFECYCLE note above.
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

        setupKVO(controller: controller)
        setupCombineSubscriptions()
    }

    // MARK: KVO

    /// Installs KVO on `controller.preferredContentSize` to trigger panel resize
    /// whenever the SwiftUI content height changes.
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

    /// Wires Combine subscriptions for `LocalRunnerStore`, `RunnerStore.didUpdate`,
    /// and `ScopeStore.didMutate` so the status icon and view model stay in sync.
    private func setupCombineSubscriptions() {
        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.didUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                log("AppDelegate > didUpdate fired -- panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
                self.updateStatusIcon()
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.start()

        ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard self != nil else { return }
                log("AppDelegate > ScopeStore.didMutate -- restarting RunnerStore")
                RunnerStore.shared.start()
            }
            .store(in: &cancellables)
    }
}
