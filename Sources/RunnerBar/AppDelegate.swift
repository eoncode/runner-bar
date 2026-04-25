import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    // Tracks whether the detail view is currently showing.
    // Used so onChange does NOT resize the popover while detail is open.
    private var isShowingDetail = false

    // ⚠️ REGRESSION GUARD — width (ref issues #52 #54)
    // WIDTH = 320. NEVER make dynamic or derive from fittingSize / hc.view.fittingSize.
    // Dynamic width → popover anchor drifts left on every data poll.
    // sizingOptions MUST remain [] — .preferredContentSize causes SwiftUI to resize
    // the popover on every layout pass → also causes left-jump.
    private static let width: CGFloat        = 320

    // ⚠️ REGRESSION GUARD — detailHeight (ref issues #52 #54)
    // Detail view height is fixed (step list is scrollable inside JobDetailView).
    // Do NOT lower below 460 — covers header + back button + ~10 step rows.
    private static let detailHeight: CGFloat = 460

    // ⚠️ HEIGHT CALCULATION — main view only (ref issues #52 #54)
    // Height is computed from actual store state so the popover fits content exactly.
    // Each section’s pixel cost is measured from the actual SwiftUI layout:
    //
    //   Fixed chrome (always present):
    //     header row:       44px  (paddingTop 12 + text~20 + paddingBottom 8 + divider 1 = ~41, round up)
    //     jobs label:       26px  (paddingTop 8 + caption~10 + paddingBottom 2 + 6 bottom padding)
    //     divider below jobs: 1px
    //     scopes section:   80px  (label 26 + 1 scope row 26 + input field 38 = 90, but VStack spacing eats some)
    //     divider:           1px
    //     toggle row:       38px  (paddingVertical 8 ×2 + checkbox~22)
    //     divider:           1px
    //     quit row:         38px  (paddingVertical 8 ×2 + text~22)
    //   Fixed chrome total: 229px
    //
    //   Variable sections:
    //     "No active jobs" row:   22px  (shown only when jobs == 0)
    //     each job row:           26px  (paddingVertical 3×2 + row content~20)
    //     .padding(.bottom, 6) when jobs > 0: 6px
    //     runners label:          26px  (shown only when runners > 0)
    //     each runner row:        32px  (paddingVertical 5×2 + row content~22)
    //     divider after runners:   1px  (shown only when runners > 0)
    //
    // ⚠️ If you change padding values in PopoverMainView, update these constants too.
    private static let fixedChrome:     CGFloat = 229
    private static let emptyJobsRow:    CGFloat = 22
    private static let jobRowHeight:    CGFloat = 26
    private static let jobsBottomPad:   CGFloat = 6
    private static let runnersLabel:    CGFloat = 26
    private static let runnerRowHeight: CGFloat = 32
    private static let runnersDivider:  CGFloat = 1
    // Minimum height so the popover never collapses to nothing
    private static let minHeight:       CGFloat = 200

    /// Computes exact popover height from current RunnerStore state.
    /// Called on every onChange so the popover always fits its content.
    /// ⚠️ Only call this when isShowingDetail == false.
    private static func computeMainHeight() -> CGFloat {
        let jobCount     = min(RunnerStore.shared.jobs.count, 3)
        let runnerCount  = RunnerStore.shared.runners.count

        var h = fixedChrome

        if jobCount == 0 {
            h += emptyJobsRow
        } else {
            h += CGFloat(jobCount) * jobRowHeight + jobsBottomPad
        }

        if runnerCount > 0 {
            h += runnersLabel + CGFloat(runnerCount) * runnerRowHeight + runnersDivider
        }

        return max(h, minHeight)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let size = NSSize(width: Self.width, height: Self.computeMainHeight())
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
            // ⚠️ Only resize when showing the main view.
            // If detail is open, leave its height (detailHeight) untouched.
            // Resizing while detail is open would flash the wrong height.
            guard !self.isShowingDetail else { return }
            let newHeight = Self.computeMainHeight()
            let newSize   = NSSize(width: Self.width, height: newHeight)
            self.hc?.view.setFrameSize(newSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                self.popover?.contentSize = newSize
            }
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
            // Return to main view. Recompute height from current store state.
            let h = Self.computeMainHeight()
            self.navigate(to: self.mainView(), height: h)
        }))
    }

    // ⚠️ REGRESSION GUARD — navigation (ref issues #52 #54)
    // Swaps content IN-PLACE. NEVER navigate by calling performClose() + show().
    // Close + reopen forces macOS to re-anchor the popover → left-jump every time.
    // Width ALWAYS stays Self.width (320). Only height changes.
    private func navigate(to view: AnyView, height: CGFloat) {
        guard let popover, let hc else { return }
        // Track detail state so onChange skip-guard above works correctly.
        isShowingDetail = (height == Self.detailHeight)
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
