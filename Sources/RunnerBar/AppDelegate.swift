import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    private static let mainSize   = NSSize(width: 320, height: 360)
    private static let detailSize = NSSize(width: 320, height: 460)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = []
        hc.view.frame = NSRect(origin: .zero, size: Self.mainSize)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = Self.mainSize
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }
        RunnerStore.shared.start()
    }

    // MARK: - View factories

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

    // MARK: - Navigation

    private func showDetail(job: ActiveJob) {
        guard let popover, let hc else { return }
        popover.performClose(nil)
        hc.rootView = detailView(job: job)
        popover.contentSize = Self.detailSize
        hc.view.setFrameSize(Self.detailSize)
        DispatchQueue.main.async { [weak self] in self?.openPopover() }
    }

    private func showMain() {
        guard let popover, let hc else { return }
        popover.performClose(nil)
        hc.rootView = mainView()
        popover.contentSize = Self.mainSize
        hc.view.setFrameSize(Self.mainSize)
        DispatchQueue.main.async { [weak self] in self?.openPopover() }
    }

    // MARK: - Toggle

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
