import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let observable = RunnerStoreObservable()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "RunnerBar")
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                let icon = NSImage(
                    systemSymbolName: RunnerStore.shared.aggregateStatus.symbolName,
                    accessibilityDescription: "RunnerBar"
                )
                icon?.isTemplate = true
                self.statusItem?.button?.image = icon
                self.observable.reload()
            }
        }

        guard githubToken() != nil else {
            let icon = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "RunnerBar")
            icon?.isTemplate = true
            statusItem?.button?.image = icon
            return
        }

        if !ScopeStore.shared.isEmpty {
            RunnerStore.shared.start()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Recreate the hosting controller every time to prevent layout drift
            // on second and subsequent opens (NSHostingController loses Auto Layout
            // anchors after NSPopover dismissal).
            let hc = NSHostingController(rootView: PopoverView(store: observable))
            hc.preferredContentSize = NSSize(width: 280, height: 400)
            popover.contentViewController = hc
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}
