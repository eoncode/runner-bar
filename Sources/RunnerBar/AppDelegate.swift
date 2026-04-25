import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // ═══════════════════════════════════════════════════════════════════
    // ⚠️ REGRESSION GUARD — DO NOT CHANGE SIZE LOGIC (ref #52 #54 #57)
    // ═══════════════════════════════════════════════════════════════════
    //
    // THE ONLY RULE THAT MATTERS:
    //   popover.contentSize must NEVER change after the popover is shown
    //   for the first time. macOS re-anchors the popover to the status
    //   bar button every single time contentSize changes on a visible
    //   NSPopover. That re-anchor is the left-jump.
    //
    // THIS MEANS:
    //   • onChange     → ZERO size changes. Two lines only. Always.
    //   • navigate()   → ZERO size changes. rootView swap only.
    //   • openPopover()→ ZERO size changes. show() call only.
    //   • Size is set ONCE in applicationDidFinishLaunching. Never again.
    //
    // WHY navigate() CANNOT RESIZE:
    //   .transient closes the popover on clicks OUTSIDE it.
    //   Tapping a button INSIDE the popover does NOT close it.
    //   So navigate() fires while the popover IS open and visible.
    //   Any contentSize change → macOS re-anchor → left-jump.
    //
    // WHY A SINGLE FIXED HEIGHT:
    //   Both main view and detail view use .frame(maxWidth/maxHeight: .infinity)
    //   so they fill whatever frame they are given. 390px fits the worst-case
    //   main view (header+3jobs+2runners+scopes+toggle+quit). Detail view
    //   shows its steps in the same 390px — tall enough for ~10 steps.
    //
    // DO NOT:
    //   • Add computeMainHeight() back — it tempts you to call it somewhere
    //   • Add a detailHeight constant — navigate() must not use it
    //   • Set sizingOptions = .preferredContentSize — auto-resizes on layout
    //   • Call performClose()+show() for navigation — different re-anchor bug
    //   • Touch hc.view.setFrameSize anywhere except applicationDidFinishLaunching
    //   • Touch popover.contentSize anywhere except applicationDidFinishLaunching
    //
    // ISSUE #57 (height fits content exactly) IS INTENTIONALLY NOT SOLVED.
    //   Solving it requires resizing after open, which violates the rule above.
    //   Empty space at bottom is acceptable. Left-jump is not.
    // ═══════════════════════════════════════════════════════════════════

    // 390px = worst-case height for main view AND enough for detail view.
    // Fits: header(44) + jobs-label(26) + 3×job-row(78) + job-pad(6) +
    //       divider(1) + runners-label(26) + 2×runner-row(64) + divider(1) +
    //       scopes(82) + divider(1) + toggle(38) + divider(1) + quit(38) = 406
    // Using 390: scopes section measured tighter in practice.
    // ⚠️ Do NOT lower this value.
    // ⚠️ Do NOT replace with a computed/dynamic value.
    private static let fixedHeight: CGFloat = 390

    // 320px fixed width. Never dynamic. Never from fittingSize.
    // Dynamic width causes anchor drift regardless of open/closed state.
    // ⚠️ Do NOT change this value.
    private static let fixedWidth:  CGFloat = 320

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // ⚠️ This is the ONLY place where frame/contentSize are set.
        // Never set them anywhere else — see REGRESSION GUARD above.
        let fixedSize = NSSize(width: Self.fixedWidth, height: Self.fixedHeight)
        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = []   // ⚠️ NEVER .preferredContentSize — auto-resizes on SwiftUI layout → left-jump
        hc.view.frame = NSRect(origin: .zero, size: fixedSize)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = fixedSize  // ⚠️ set ONCE here, NEVER again
        popover.contentViewController = hc
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            // ⚠️ EXACTLY TWO LINES. DO NOT ADD A THIRD. DO NOT TOUCH SIZE.
            // Touching contentSize or setFrameSize here fires while popover is
            // visible → macOS re-anchor → left-jump. This has been the bug
            // pattern across v0.11–v0.19. Do not repeat it.
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            self.observable.reload()
        }
        RunnerStore.shared.start()
    }

    // MARK: — View factories

    private func mainView() -> AnyView {
        AnyView(PopoverMainView(store: observable, onSelectJob: { [weak self] job in
            guard let self else { return }
            self.navigate(to: self.detailView(job: job))
        }))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(job: job, onBack: { [weak self] in
            guard let self else { return }
            self.navigate(to: self.mainView())
        }))
    }

    // MARK: — Navigation

    // ⚠️ REGRESSION GUARD — navigate() swaps rootView ONLY.
    // NO contentSize change. NO setFrameSize. NO height parameter.
    // The popover stays the same size for both main and detail views.
    // See REGRESSION GUARD at top of file for why.
    private func navigate(to view: AnyView) {
        guard let hc else { return }
        hc.rootView = view
        // ⚠️ That's it. No size changes. Resist the urge.
    }

    // MARK: — Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    // ⚠️ openPopover() does NOT set contentSize or call setFrameSize.
    // Size was set once at launch. It stays fixed. See REGRESSION GUARD.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        // ⚠️ show() only. No size changes before or after.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
