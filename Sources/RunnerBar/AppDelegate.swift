import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ REGRESSION GUARD — THE TWO INVARIANTS (ref issues #52 #54 #57)
    //
    // INVARIANT 1 — NO LEFT-JUMP:
    //   popover.contentSize must NEVER change while the popover is OPEN/VISIBLE.
    //   macOS re-anchors the popover window every time contentSize changes on a
    //   visible NSPopover. This shifts it left. Period.
    //   → onChange:     NEVER touch contentSize or setFrameSize. TWO LINES ONLY.
    //   → openPopover(): safe to set contentSize/setFrameSize BEFORE show() call.
    //                   NEVER touch hc.rootView here — reassigning rootView
    //                   triggers a SwiftUI layout pass that fires AFTER show()
    //                   while the popover is becoming visible → LEFT-JUMP.
    //   → navigate():   safe to set contentSize/setFrameSize — .transient
    //                   popover is closed by the time a tap inside it registers.
    //
    // INVARIANT 2 — HEIGHT FITS CONTENT:
    //   computeMainHeight() is called in openPopover() (before show) and in
    //   navigate()-back-to-main (popover closed by .transient). Both are safe
    //   sites for Invariant 1 — the popover is closed at both call sites.
    //
    // NEVER:
    //   - Call computeMainHeight() or touch size inside onChange
    //   - Set sizingOptions = .preferredContentSize
    //   - Call performClose()+show() for navigation
    //   - Touch hc.rootView inside openPopover()

    // WIDTH is always 320. Never dynamic.
    private static let width:        CGFloat = 320
    // detailHeight fixed at 460. Step list is scrollable.
    private static let detailHeight: CGFloat = 460

    // MARK: — Height computation

    // Computes exact main-view height from current store state.
    // ⚠️ ONLY call when popover is CLOSED. Never from onChange.
    //
    // Pixel costs (must match PopoverMainView.swift padding values exactly):
    //   header:               44px
    //   "Active Jobs" label:  26px
    //   divider:               1px
    //   scopes section:       82px
    //   divider:               1px
    //   toggle row:           38px
    //   divider:               1px
    //   quit row:             38px
    //   fixed chrome total:  231px
    //
    //   "No active jobs" row: 22px  (when jobs == 0)
    //   each job row:         26px  (when jobs > 0)
    //   job list bottom pad:   6px  (when jobs > 0)
    //   runners label:        26px  (when runners > 0)
    //   each runner row:      32px  (when runners > 0)
    //   runners divider:       1px  (when runners > 0)
    //
    // ⚠️ If you change ANY padding in PopoverMainView.swift update these constants.
    private static func computeMainHeight() -> CGFloat {
        let jobCount    = min(RunnerStore.shared.jobs.count, 3)
        let runnerCount = RunnerStore.shared.runners.count
        var h: CGFloat  = 231
        h += jobCount == 0 ? 22 : CGFloat(jobCount) * 26 + 6
        if runnerCount > 0 { h += 26 + CGFloat(runnerCount) * 32 + 1 }
        return max(h, 200)
    }

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let initialSize = NSSize(width: Self.width, height: Self.computeMainHeight())
        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = []  // ⚠️ NEVER .preferredContentSize — causes left-jump
        hc.view.frame = NSRect(origin: .zero, size: initialSize)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = initialSize
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            // ⚠️ TWO LINES ONLY. NOTHING THAT TOUCHES SIZE. EVER.
            // Any contentSize / setFrameSize call here fires while the popover
            // is visible → macOS re-anchors → left-jump. Don’t do it.
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }
        RunnerStore.shared.start()
    }

    // MARK: — View factories

    private func mainView() -> AnyView {
        AnyView(PopoverMainView(store: observable, onSelectJob: { [weak self] job in
            guard let self else { return }
            self.navigate(to: self.detailView(job: job), height: Self.detailHeight)
        }))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(job: job, onBack: { [weak self] in
            guard let self else { return }
            self.navigate(to: self.mainView(), height: Self.computeMainHeight())
        }))
    }

    // MARK: — Navigation

    // ⚠️ ONLY place besides openPopover() where contentSize may change.
    // In-place swap — NEVER performClose()+show() for nav — that re-anchors.
    // Width always Self.width (320). Never anything else.
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

    // MARK: — Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    // openPopover() — the ONLY place we size the popover to fit content.
    // Guaranteed safe: only called from togglePopover’s else-branch where
    // popover.isShown == false, so contentSize/setFrameSize do not trigger
    // macOS re-anchor (Invariant 1 preserved).
    //
    // ⚠️ DO NOT reassign hc.rootView here.
    //    Reassigning rootView creates a new SwiftUI view tree. SwiftUI defers
    //    some layout work to the next run-loop tick, which fires AFTER show()
    //    while the popover is becoming visible → triggers re-anchor → left-jump.
    //    hc.rootView is already the main view: navigate() always resets it to
    //    mainView() on Back, and .transient closes the popover before the user
    //    can navigate away, so we are always at main view when isShown==false.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc else { return }

        // Size to fit current content — safe because isShown == false.
        // DO NOT touch hc.rootView — see warning above.
        let newSize = NSSize(width: Self.width, height: Self.computeMainHeight())
        hc.view.setFrameSize(newSize)
        popover.contentSize = newSize

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
