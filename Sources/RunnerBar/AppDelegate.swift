import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate \u203a applicationDidFinishLaunching")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hc = NSHostingController(rootView: PopoverView(store: observable))
        // Let SwiftUI drive the popover height via its own intrinsic size.
        // The PopoverView caps jobListView at maxHeight:480, so it never grows unbounded.
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentViewController = hc
        // Width is fixed; height is driven by sizingOptions above.
        hc.view.setFrameSize(NSSize(width: 340, height: hc.view.fittingSize.height))
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate \u203a onChange \u2014 refreshing status icon")
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }

        RunnerStore.shared.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            log("AppDelegate \u203a opening popover")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}
