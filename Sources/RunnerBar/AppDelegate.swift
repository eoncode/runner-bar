import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    private static let width: CGFloat = 320
    private static let mainHeight: CGFloat   = 360
    private static let detailHeight: CGFloat = 460

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let size = NSSize(width: Self.width, height: Self.mainHeight)
        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = []
        hc.view.frame = NSRect(origin: .zero, size: size)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = size
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }
        RunnerStore.shared.start()
    }

    private func mainView() -> AnyView {
        AnyView(PopoverMainView(store: observable, onSelectJob: { [weak self] job in
            self?.showDetail(job: job)
        }))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(job: job, onBack: { [weak self] in
            self?.showMain()
        }))
    }

    private func showDetail(job: ActiveJob) {
        swap(to: detailView(job: job), height: Self.detailHeight)
    }

    private func showMain() {
        swap(to: mainView(), height: Self.mainHeight)
    }

    private func swap(to view: AnyView, height: CGFloat) {
        guard let popover, let hc else { return }
        popover.performClose(nil)
        hc.rootView = view
        // Only height changes — width is always 320
        let newSize = NSSize(width: Self.width, height: height)
        popover.contentSize = newSize
        hc.view.setFrameSize(newSize)
        DispatchQueue.main.async { [weak self] in self?.openPopover() }
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
