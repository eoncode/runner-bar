import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ REGRESSION GUARD — width/height (ref issues #52 #54)
    //
    // WIDTH = 320. NEVER make it dynamic or derive from fittingSize.
    //   Dynamic width → popover jumps left on every data update.
    //
    // mainHeight = 400. Accounts for the TALLEST possible main-view state:
    //   header(44) + divider(1) + jobs-label(26) + 3 job-rows(3×26=78) + divider(1)
    //   + runners-label(26) + 2 runner-rows(2×32=64) + divider(1)
    //   + scopes-section(82) + divider(1) + toggle(38) + divider(1) + quit(38) = ~401px
    //   → 400 is the correct floor. Do NOT lower it below 400.
    //   → If content ever shrinks (0 runners, 0 jobs), SwiftUI top-aligns and
    //     the extra whitespace at the bottom is acceptable and correct.
    //
    // detailHeight = 460. Accounts for the job-detail step list (up to ~10 steps).
    //   Do NOT lower below 460.
    //
    // sizingOptions MUST remain [] — .preferredContentSize causes SwiftUI to resize
    //   the popover on every layout pass → left-jump on every poll.
    private static let width: CGFloat        = 320
    private static let mainHeight: CGFloat   = 400  // ⚠️ do not lower — see calculation above
    private static let detailHeight: CGFloat = 460  // ⚠️ do not lower — covers ~10 step rows

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let size = NSSize(width: Self.width, height: Self.mainHeight)
        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = []  // ⚠️ NEVER change to .preferredContentSize — causes left-jump
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
            guard let self else { return }
            self.navigate(to: self.detailView(job: job), height: Self.detailHeight)
        }))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(job: job, onBack: { [weak self] in
            guard let self else { return }
            self.navigate(to: self.mainView(), height: Self.mainHeight)
        }))
    }

    // ⚠️ REGRESSION GUARD — navigation (ref issues #52 #54)
    // Swap content in-place. NEVER navigate by calling performClose() + show().
    // Closing and reopening the popover forces macOS to re-anchor from scratch → left-jump.
    // This function changes ONLY the height. Width stays Self.width (320) always.
    private func navigate(to view: AnyView, height: CGFloat) {
        guard let popover, let hc else { return }
        let newSize = NSSize(width: Self.width, height: height)
        hc.rootView = view
        hc.view.setFrameSize(newSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            popover.contentSize = newSize
        }
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
