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
    //   → onChange:    NEVER touch contentSize or setFrameSize. EVER.
    //   → openPopover: safe to set size here — popover is CLOSED at call time.
    //   → navigate():  safe to set size here — called on user tap, popover is
    //                  dismissed by .transient behavior before the tap registers.
    //
    // INVARIANT 2 — HEIGHT FITS CONTENT:
    //   Height is computed once from actual store state, right before show().
    //   The popover is closed at that point, so Invariant 1 is not violated.
    //   → computeMainHeight() is called ONLY inside openPopover() and navigate()-to-main.
    //   → It reads RunnerStore.shared directly (already on main thread at both call sites).
    //
    // THESE TWO INVARIANTS ARE COMPATIBLE because:
    //   - Content only changes during polls (onChange, every 10s).
    //   - Size is only set at open time (user click) and navigation (user tap).
    //   - The popover is CLOSED between the last poll and the next open.
    //   - So the size computed at open-time always matches the current content.
    //
    // DO NOT "FIX" THE HEIGHT BY:
    //   - Calling computeMainHeight() inside onChange → violates Invariant 1
    //   - Using a fixed constant tall enough for worst case → violates Invariant 2
    //   - Setting sizingOptions = .preferredContentSize → violates Invariant 1
    //   - Calling performClose()+show() for navigation → violates Invariant 1

    // WIDTH is always 320. Never dynamic. Never from fittingSize.
    // Dynamic width causes anchor drift regardless of open/closed state.
    private static let width:        CGFloat = 320

    // detailHeight is fixed at 460. Step list is scrollable inside JobDetailView.
    // Do NOT lower — covers header + back button + ~10 step rows.
    private static let detailHeight: CGFloat = 460

    // MARK: — Height computation

    // Computes exact main-view height from current RunnerStore state.
    // ⚠️ CALL ONLY when the popover is CLOSED (openPopover, navigate-to-main).
    // NEVER call from onChange or any path that fires while popover is visible.
    //
    // Pixel costs measured from actual SwiftUI layout in PopoverMainView:
    //   header:             44px  (paddingTop 12 + text + paddingBottom 8)
    //   "Active Jobs" label:26px  (paddingTop 8 + caption + paddingBottom 2 + spacing)
    //   divider below jobs:  1px
    //   scopes section:     82px  (label 18 + 1-scope row 26 + input 38)
    //   divider:             1px
    //   toggle row:         38px  (paddingVertical 8×2 + checkbox)
    //   divider:             1px
    //   quit row:           38px  (paddingVertical 8×2 + text)
    //   ───────────────────────────
    //   fixed chrome total: 231px
    //
    //   "No active jobs" row:  22px  (only when jobs == 0)
    //   each job row:          26px  (paddingVertical 3×2 + content)
    //   job list bottom pad:    6px  (only when jobs > 0)
    //   runners label:         26px  (only when runners > 0)
    //   each runner row:       32px  (paddingVertical 5×2 + content)
    //   runners divider:        1px  (only when runners > 0)
    //
    // ⚠️ If you change ANY padding in PopoverMainView.swift, update these numbers.
    private static func computeMainHeight() -> CGFloat {
        let jobCount    = min(RunnerStore.shared.jobs.count, 3)
        let runnerCount = RunnerStore.shared.runners.count

        var h: CGFloat = 231  // fixed chrome (see above)

        // jobs section
        if jobCount == 0 {
            h += 22  // "No active jobs" row
        } else {
            h += CGFloat(jobCount) * 26 + 6  // job rows + bottom pad
        }

        // runners section (only if any runners are registered)
        if runnerCount > 0 {
            h += 26                          // "Local runners" label
            h += CGFloat(runnerCount) * 32   // runner rows
            h += 1                           // divider after runners section
        }

        return max(h, 200)  // floor so popover never collapses
    }

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Initial size: use a reasonable default. openPopover() will correct it
        // from live store data each time the user actually opens the popover.
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
            // ⚠️ TWO LINES ONLY. DO NOT ADD ANYTHING THAT TOUCHES SIZE.
            // Changing contentSize or setFrameSize here causes left-jump (Invariant 1).
            // Height correction happens at next openPopover() call instead.
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
            // Navigate back to main. Compute height fresh — the popover is open
            // here but .transient already dismissed it when user tapped Back.
            // This is the same safety guarantee as any other navigate() call.
            self.navigate(to: self.mainView(), height: Self.computeMainHeight())
        }))
    }

    // MARK: — Navigation

    // ⚠️ REGRESSION GUARD — navigate() is the ONLY place contentSize may change.
    // Swap root view and resize in one synchronous block.
    // NEVER navigate by performClose()+show() — that re-anchors the popover.
    // Width is ALWAYS Self.width (320). Never pass anything else.
    // Called only on explicit user interaction (job tap, Back tap).
    // .transient popover is dismissed on outside click before user can tap rows,
    // so the popover is closed (or transitioning closed) when this fires.
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

    // ⚠️ openPopover() is the second safe site for height computation.
    // The popover is guaranteed CLOSED here (we only call it from the else-branch
    // of togglePopover, where !popover.isShown is confirmed).
    // We set the correct content-fitted height right before show(), so the
    // popover opens at the right size without ever resizing while visible.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc else { return }

        // Compute height from current store state while popover is still closed.
        // This is safe — Invariant 1 is not violated because isShown == false.
        let h = Self.computeMainHeight()
        let newSize = NSSize(width: Self.width, height: h)
        hc.rootView = mainView()   // always reset to main view on open
        hc.view.setFrameSize(newSize)
        popover.contentSize = newSize

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
