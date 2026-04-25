import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  REGRESSION GUARD — READ THIS ENTIRE COMMENT BEFORE CHANGING ANYTHING
// ═══════════════════════════════════════════════════════════════════════════════
//
// This was broken and rewritten 30+ times. READ BEFORE TOUCHING.
// See issues #52, #54, #57, #59.
//
// ── ARCHITECTURE ────────────────────────────────────────────────────────────
//   sizingOptions = []   (NEVER .preferredContentSize)
//   popover.contentSize set manually, ONLY in two safe places:
//     1. applicationDidFinishLaunching (popover not yet shown)
//     2. openPopover() (popover is CLOSED, isShown==false guaranteed)
//   navigate() swaps hc.rootView ONLY. Zero size changes. Ever.
//
// ── WHY NOT preferredContentSize ──────────────────────────────────────────────
//   preferredContentSize causes NSPopover to re-anchor on every hc.rootView
//   swap. When navigate() swaps main→detail or detail→main, SwiftUI computes
//   a new ideal size. NSPopover sees contentSize change → re-anchors X+Y
//   → left-jump. This was v0.25’s mistake.
//   ❌ NEVER change sizingOptions to .preferredContentSize
//
// ── THE LEFT-JUMP RULE (#52 #54) ────────────────────────────────────────────
//   macOS re-anchors NSPopover to status bar button every time contentSize
//   changes while the popover is VISIBLE. That re-anchor IS the left-jump.
//   contentSize/setFrameSize are FORBIDDEN while popover.isShown == true.
//
// ── THE HEIGHT-FITS-CONTENT RULE (#57) ───────────────────────────────────────
//   Height is computed fresh in openPopover() every time before show().
//   openPopover() is ONLY called from togglePopover()’s else-branch,
//   where isShown==false is guaranteed. Safe to resize there.
//
// ── SAFE OPERATIONS PER CALL SITE ───────────────────────────────────────────
//
//   applicationDidFinishLaunching:
//     ✔ set frame / contentSize (popover not yet created)
//
//   onChange (fires every ~10s while popover may be OPEN):
//     ✔ statusItem icon update
//     ✔ observable.reload()
//     ✖ contentSize  ← LEFT-JUMP
//     ✖ setFrameSize ← LEFT-JUMP
//
//   navigate() (fires while popover IS open — user tapped inside):
//     ✔ hc.rootView = newView  (SwiftUI updates in-place, no re-anchor)
//     ✖ contentSize  ← LEFT-JUMP
//     ✖ setFrameSize ← LEFT-JUMP
//
//   openPopover() (isShown == false, guaranteed):
//     ✔ setFrameSize  (popover is CLOSED)
//     ✔ contentSize   (popover is CLOSED)
//     ✖ hc.rootView   ← new SwiftUI tree → deferred layout fires AFTER show() → LEFT-JUMP
//
// ── ABSOLUTE NEVER LIST ────────────────────────────────────────────────────═
//   ❌ sizingOptions = .preferredContentSize → re-anchors on every rootView swap
//   ❌ contentSize while isShown==true → left-jump
//   ❌ setFrameSize while isShown==true → left-jump
//   ❌ hc.rootView in openPopover() → deferred layout → left-jump
//   ❌ .frame(idealWidth:) on views → only meaningful under preferredContentSize
//
// ═══════════════════════════════════════════════════════════════════════════════

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // Fixed width. Never dynamic. Dynamic width = anchor drift = left-jump.
    private static let fixedWidth: CGFloat = 320

    // MARK: — Height computation
    //
    // Computes main-view height from current store state.
    // ⚠️ Called ONLY from openPopover() where isShown == false.
    // ⚠️ NEVER call from onChange, navigate(), or any other site.
    //
    // Pixel budget (must match PopoverMainView.swift padding values EXACTLY):
    //   header:              44px  (paddingTop 12 + content + paddingBottom 8)
    //   "Active Jobs" label: 26px  (paddingTop 8 + caption + paddingBottom 2)
    //   divider:              1px
    //   scopes block:        82px  (label 18 + 1-scope row 26 + input 38)
    //   divider:              1px
    //   toggle row:          38px  (paddingVertical 8 each side)
    //   divider:              1px
    //   quit row:            38px  (paddingVertical 8 each side)
    //   fixed chrome:       231px
    //
    //   "No active jobs":    22px  (only when jobCount == 0)
    //   each job row:        26px  (paddingVertical 3 each side + content ~20)
    //   job-list pad:         6px  (only when jobCount > 0)
    //   runners label:       26px  (only when runnerCount > 0)
    //   each runner row:     32px  (paddingVertical 5 each side + content ~22)
    //   runners divider:      1px  (only when runnerCount > 0)
    //
    // ⚠️ If you change ANY padding in PopoverMainView.swift, update these numbers.
    private static func computeMainHeight() -> CGFloat {
        let jobs    = min(RunnerStore.shared.jobs.count, 3)
        let runners = RunnerStore.shared.runners.count
        var h: CGFloat = 231
        h += jobs == 0 ? 22 : CGFloat(jobs) * 26 + 6
        if runners > 0 { h += 26 + CGFloat(runners) * 32 + 1 }
        return max(h, 200)
    }

    // Height for the detail view: fixed at enough to show all steps comfortably.
    // Steps are ~26px each. Header ~60px. Divider + padding ~20px.
    // Max 20 steps = 520 + 80 = 600px, but cap at 520 to stay on screen.
    // ⚠️ This is set in openPopover() ONLY when navigating, not during navigation.
    // ⚠️ We CANNOT resize during navigate() (popover is open = left-jump).
    // ⚠️ So detail height is set at OPEN time based on last known job.
    // For now use a fixed generous height that fits most step lists.
    private static let detailHeight: CGFloat = 480

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let initialSize = NSSize(width: Self.fixedWidth, height: Self.computeMainHeight())
        let hc = NSHostingController(rootView: mainView())
        // ⚠️ sizingOptions MUST be [] (empty). NEVER .preferredContentSize.
        // .preferredContentSize causes re-anchor on every hc.rootView swap.
        hc.sizingOptions = []  // ❌ NEVER change to .preferredContentSize
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
            // ⚠️ EXACTLY TWO LINES. NEVER ADD A THIRD. NEVER TOUCH SIZE.
            // This fires every ~10s. If popover is visible, any size change = left-jump.
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
            // ⚠️ No size change here. openPopover() resizes on next open.
        }))
    }

    // MARK: — Navigation

    // ⚠️ REGRESSION GUARD: rootView swap ONLY. ZERO size changes. FOREVER.
    // navigate() fires while the popover IS open (user tapped inside it).
    // .transient only closes on clicks OUTSIDE — not on taps inside.
    // Any contentSize/setFrameSize here = popover visible = LEFT-JUMP.
    // Width and height stay as set by openPopover(). No exceptions. No compromises.
    private func navigate(to view: AnyView) {
        guard let hc else { return }
        hc.rootView = view
        // ⚠️ THAT IS ALL. Do not add ANYTHING else here. Ever.
    }

    // MARK: — Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    // openPopover() — the ONE safe site for sizing.
    // Called ONLY from togglePopover()’s else-branch: isShown==false guaranteed.
    // popover.contentSize on a CLOSED popover does NOT trigger macOS re-anchor.
    //
    // ⚠️ DO NOT reassign hc.rootView here.
    //   Reassigning rootView discards the SwiftUI tree and builds a new one.
    //   SwiftUI defers part of that work to the next run-loop tick, which fires
    //   AFTER show() while the popover is becoming visible → macOS re-anchors → left-jump.
    //   hc.rootView is already mainView() because:
    //     • We initialise it as mainView() in applicationDidFinishLaunching.
    //     • navigate()-to-Back always resets it to mainView().
    //     • .transient closes before any outside-click; user can’t open while on detail.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc else { return }

        // Resize to fit current content. Safe: isShown==false (see above).
        // ⚠️ NO hc.rootView change here.
        let h = Self.computeMainHeight()
        let newSize = NSSize(width: Self.fixedWidth, height: h)
        hc.view.setFrameSize(newSize)
        popover.contentSize = newSize

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
