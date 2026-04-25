import AppKit
import SwiftUI

/// Hosting controller that fixes width at 340 pt while letting SwiftUI
/// determine the height freely (used so the popover never jumps sideways).
private final class FixedWidthHostingController<V: View>: NSHostingController<V> {
    override var preferredContentSize: NSSize {
        get {
            let s = super.preferredContentSize
            return NSSize(width: 340, height: s.height)
        }
        set { super.preferredContentSize = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: FixedWidthHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate > applicationDidFinishLaunching")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hc = FixedWidthHostingController(rootView: PopoverView(store: observable))
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate > onChange - refreshing status icon")
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
            log("AppDelegate > opening popover")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}
