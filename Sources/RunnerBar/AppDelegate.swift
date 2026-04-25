import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  REGRESSION GUARD — READ THIS ENTIRE COMMENT BEFORE CHANGING ANYTHING
// ═══════════════════════════════════════════════════════════════════════════════
//
// This was broken and rewritten 30+ times. READ BEFORE TOUCHING.
// See issues #52, #54, #57, #59.
//
// ── ARCHITECTURE ─────────────────────────────────────────────────────────────
//   sizingOptions: default (NOT set to .preferredContentSize, NOT set to [])
//   Height is read via hc.view.fittingSize.height ONCE per open in openPopover().
//   fittingSize reads SwiftUI ideal size ONE TIME while popover is CLOSED.
//   sizingOptions=.preferredContentSize would re-read it CONTINUOUSLY → re-anchor → jump.
//   So we rely on the default (which is []) and read fittingSize manually.
//   popover.contentSize set manually ONLY in two safe places:
//     1. applicationDidFinishLaunching (popover not yet shown)
//     2. openPopover() (popover is CLOSED, isShown==false guaranteed)
//   navigate() swaps hc.rootView ONLY. Zero size changes. Ever.
//
// ── NAVIGATION LEVELS ───────────────────────────────────────────────────────────
//   Level 1: PopoverMainView   — job list + runners + settings
//   Level 2: JobDetailView     — step list for a selected job
//   Level 3: StepLogView       — log output for a selected step
//   All levels use navigate() (rootView swap). Zero size changes on navigation.
//   ScrollView in levels 2+3 absorbs content overflow within the fixed frame.
//
// ── WHY NOT preferredContentSize ─────────────────────────────────────────────
//   preferredContentSize causes NSPopover to re-anchor on every hc.rootView
//   swap. When navigate() swaps main→detail or detail→main, SwiftUI computes
//   a new ideal size. NSPopover sees contentSize change → re-anchors X+Y
//   → left-jump. This was v0.25's mistake.
//   ❌ NEVER set sizingOptions = .preferredContentSize
//
// ── THE LEFT-JUMP RULE (#52 #54) ─────────────────────────────────────────────
//   macOS re-anchors NSPopover to status bar button every time contentSize
//   changes while the popover is VISIBLE. That re-anchor IS the left-jump.
//   contentSize/setFrameSize are FORBIDDEN while popover.isShown == true.
//
// ── THE HEIGHT-FITS-CONTENT RULE (#57) ───────────────────────────────────────
//   Height is read via fittingSize.height in openPopover() every time.
//   openPopover() is ONLY called from togglePopover()'s else-branch,
//   where isShown==false is guaranteed. Safe to resize there.
//
// ── SAFE OPERATIONS PER CALL SITE ────────────────────────────────────────────
//
//   applicationDidFinishLaunching:
//     ✔ set frame / contentSize (popover not yet shown)
//
//   onChange (fires every ~10s while popover may be OPEN):
//     ✔ statusItem icon update
//     ✔ observable.reload() — guarded by if !popoverIsOpen
//     ✖ contentSize  ← LEFT-JUMP
//     ✖ setFrameSize ← LEFT-JUMP
//     ✖ reload() without popoverIsOpen guard ← triggers re-render → size shift → jump
//
//   navigate() (fires while popover IS open — user tapped inside):
//     ✔ hc.rootView = newView  (SwiftUI updates in-place, no re-anchor)
//     ✖ contentSize  ← LEFT-JUMP
//     ✖ setFrameSize ← LEFT-JUMP
//
//   openPopover() (isShown == false, guaranteed):
//     ✔ setFrameSize  (popover is CLOSED)
//     ✔ contentSize   (popover is CLOSED)
//     ✔ fittingSize read (reads SwiftUI ideal size once, safely)
//     ✖ hc.rootView   ← new SwiftUI tree → deferred layout fires AFTER show() → LEFT-JUMP
//
//   popoverDidClose:
//     ✔ popoverIsOpen = false
//     ✖ reload() ← objectWillChange → .transient treats as outside-click → thrash loop
//     ✖ contentSize ← LEFT-JUMP (though popover is closing, avoid for safety)
//
// ── ABSOLUTE NEVER LIST ─────────────────────────────────────────────────────
//   ❌ sizingOptions = .preferredContentSize → re-anchors on every rootView swap
//   ❌ contentSize while isShown==true → left-jump
//   ❌ setFrameSize while isShown==true → left-jump
//   ❌ hc.rootView in openPopover() → deferred layout → left-jump
//   ❌ reload() from popoverDidClose → thrash loop
//   ❌ reload() before popoverIsOpen=true → race: re-render fires after show() → jump
//   ❌ objectWillChange.send() in reload() → double re-render
//   ❌ remove .frame(idealWidth: 340) from PopoverMainView → fittingSize returns 0 width
//
// ═══════════════════════════════════════════════════════════════════════════════

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ CAUSE 2+4 guard. MUST be set to true BEFORE reload() on open.
    // Without this guard, onChange fires reload() while popover is visible
    // → SwiftUI re-render → fittingSize shifts 1pt → if preferredContentSize
    //   were active it would re-anchor. With default sizingOptions it won't,
    //   but guard is still correct to prevent unnecessary re-renders.
    // ❌ NEVER remove this flag.
    private var popoverIsOpen = false

    // Fixed width. PopoverMainView uses .frame(idealWidth: 340) to match.
    // fittingSize reads this idealWidth for the width component.
    // ❌ NEVER make width dynamic — anchor drift = left-jump.
    private static let fixedWidth: CGFloat = 340

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // ⚠️ sizingOptions is NOT set here — default is [] which is correct.
        // ❌ NEVER set sizingOptions = .preferredContentSize (re-anchors on rootView swap)
        // ❌ NEVER set sizingOptions = [] explicitly (same as default, but confusing)
        let hc = NSHostingController(rootView: mainView())
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        hc.view.frame = NSRect(origin: .zero, size: initialSize)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentSize           = initialSize
        popover.contentViewController = hc
        popover.delegate              = self
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            // ⚠️ EXACTLY TWO OPERATIONS. NEVER ADD A THIRD. NEVER TOUCH SIZE.
            // This fires every ~10s. popoverIsOpen guard prevents re-render while visible.
            // Any size change here = left-jump (popover may be visible).
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ⚠️ CAUSE 2: guard prevents SwiftUI re-render while popover is open.
            // Without this guard, re-render can shift fittingSize 1pt → potential anchor drift.
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }
        RunnerStore.shared.start()
    }

    // MARK: — NSPopoverDelegate

    // ⚠️ CAUSE 3: ONLY set flag here. NEVER call reload() from popoverDidClose.
    // Calling reload() here fires objectWillChange → .transient treats as
    // outside-click → open/close thrash loop on every single click.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false  // ❌ NEVER add reload() or contentSize here
        // Reset to main view so next open always starts at level 1.
        // Safe: popover is already closed, no re-anchor possible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hc?.rootView = self.mainView()
        }
    }

    // MARK: — View factories

    private func mainView() -> AnyView {
        AnyView(PopoverMainView(store: observable, onSelectJob: { [weak self] job in
            guard let self else { return }
            self.navigate(to: self.detailView(job: job))
        }))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                self.navigate(to: self.logView(job: job, step: step))
            }
        ))
    }

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
        ))
    }

    // MARK: — Navigation

    // ⚠️ REGRESSION GUARD: rootView swap ONLY. ZERO size changes. FOREVER.
    // navigate() fires while the popover IS open (user tapped inside it).
    // .transient only closes on clicks OUTSIDE — not on taps inside.
    // Any contentSize/setFrameSize here = popover visible = LEFT-JUMP.
    // preferredContentSize is NOT set, so rootView swap does NOT re-anchor.
    private func navigate(to view: AnyView) {
        hc?.rootView = view
        // ⚠️ THAT IS ALL. Do not add ANYTHING else here. Ever.
    }

    // MARK: — Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    // openPopover() — the ONE safe site for sizing.
    // Called ONLY from togglePopover()'s else-branch: isShown==false guaranteed.
    //
    // KEY INSIGHT: fittingSize is read ONCE here while popover is CLOSED.
    // This gives correct dynamic height without the continuous re-reading that
    // preferredContentSize does. No re-anchor risk.
    //
    // ⚠️ CAUSE 4: ORDER IS NON-NEGOTIABLE:
    //   Step 1: popoverIsOpen = true   (guard is live before reload fires)
    //   Step 2: observable.reload()    (fresh data → SwiftUI updates view tree)
    //   Step 3: read fittingSize       (reads updated SwiftUI ideal size)
    //   Step 4: setFrameSize + contentSize  (safe: isShown==false)
    //   Step 5: show()
    //
    // ⚠️ DO NOT reassign hc.rootView here.
    //   Reassigning rootView discards the SwiftUI tree and builds a new one.
    //   SwiftUI defers layout to next run-loop tick → fires AFTER show() → left-jump.
    //   hc.rootView is always mainView() here because:
    //     • Initialised as mainView() in applicationDidFinishLaunching.
    //     • popoverDidClose resets it to mainView().
    //     • .transient closes on outside-click before user can re-open on detail/log.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc else { return }

        // ⚠️ CAUSE 4: popoverIsOpen MUST be set before reload()
        popoverIsOpen = true              // ❌ NEVER move below reload()
        observable.reload()               // ❌ NEVER move above popoverIsOpen = true

        // Read fittingSize AFTER reload() so SwiftUI has fresh data.
        // fittingSize.width comes from .frame(idealWidth: 340) in PopoverMainView.
        // fittingSize.height comes from VStack intrinsic content height.
        // ❌ NEVER read fittingSize before reload() — stale data = wrong height
        // ❌ NEVER remove .frame(idealWidth: 340) from PopoverMainView — fittingSize.width = 0
        let size = NSSize(width: hc.view.fittingSize.width > 0 ? hc.view.fittingSize.width : Self.fixedWidth,
                          height: hc.view.fittingSize.height)

        // Safe to resize: popover is CLOSED (isShown==false guaranteed)
        // ❌ NEVER do this while isShown==true — LEFT-JUMP
        hc.view.setFrameSize(size)
        popover.contentSize = size

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
