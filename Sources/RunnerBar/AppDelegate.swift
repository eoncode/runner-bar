import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    // Navigation state lives here in AppDelegate so we can re-anchor
    // the popover (via show(relativeTo:of:preferredEdge:)) whenever the
    // content size changes. Toggling this calls showPopover() which
    // sets the new contentSize BEFORE showing, preventing the (0,0) jump.
    var selectedJob: ActiveJob? = nil {
        didSet {
            // Update the hosted root view with the new selection.
            if let hc {
                hc.rootView = PopoverView(
                    store: observable,
                    selectedJob: selectedJob,
                    onSelectJob: { [weak self] job in self?.selectedJob = job },
                    onBack: { [weak self] in self?.selectedJob = nil }
                )
            }
            // Re-show the popover so it re-anchors at the correct position
            // with the updated contentSize. This is the only reliable fix.
            if popover?.isShown == true {
                showPopover()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate \u203a applicationDidFinishLaunching")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let rootView = PopoverView(
            store: observable,
            selectedJob: nil,
            onSelectJob: { [weak self] job in self?.selectedJob = job },
            onBack: { [weak self] in self?.selectedJob = nil }
        )
        let hc = NSHostingController(rootView: rootView)
        hc.sizingOptions = []
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = Self.mainSize
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate \u203a onChange")
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }

        RunnerStore.shared.start()
    }

    // MARK: - Sizes

    private static let mainSize   = NSSize(width: 320, height: 420)
    private static let detailSize = NSSize(width: 320, height: 420)

    // MARK: - Toggle

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover, let hc else { return }

        // Set size BEFORE showing so the anchor calculation uses correct size.
        let size = (selectedJob == nil) ? Self.mainSize : Self.detailSize
        popover.contentSize = size
        hc.view.setFrameSize(size)
        hc.view.layoutSubtreeIfNeeded()

        log("AppDelegate \u203a showPopover size=\(size) isShown=\(popover.isShown)")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
