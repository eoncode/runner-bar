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
//   sizingOptions: default (NOT set to .preferredContentSize, NOT set to [])\n//   Height is read via hc.view.fittingSize.height ONCE per open in openPopover().
//   fittingSize reads SwiftUI ideal size ONE TIME while popover is CLOSED.
//   sizingOptions=.preferredContentSize would re-read it CONTINUOUSLY → re-anchor → jump.
//   So we rely on the default (which is []) and read fittingSize manually.
//   popover.contentSize set manually ONLY in two safe places:
//     1. applicationDidFinishLaunching (popover not yet shown)
//     2. openPopover() (popover is CLOSED, isShown==false guaranteed)
//   navigate() swaps hc.rootView ONLY. Zero size changes. Ever.
//
// ── NAVIGATION LEVELS ───────────────────────────────────────────────────────────
//   Level 1: PopoverMainView   — job list + runner status
//   Level 2: JobDetailView     — step list for a selected job
//   Level 3: StepLogView       — log output for a selected step
//
//   All levels navigate via navigate() — rootView swap only, ZERO size changes.
//   All levels use ScrollView for content that may overflow the fixed frame.
//   The fixed frame is sized ONCE in openPopover() from mainView()'s fittingSize.
//   Because the frame never changes after open, all levels must fit within it
//   using their own ScrollView — that is the correct contract, not fighting the frame.
//
//   Back-navigation chain:
//     StepLogView.onBack    → navigate(to: detailView(job:))
//     JobDetailView.onBack  → navigate(to: mainView())
//     popoverDidClose       → reset hc.rootView = mainView() (async, popover already closed)
//
// ── WHY NOT preferredContentSize ─────────────────────────────────────────────
//   preferredContentSize causes NSPopover to re-anchor on every hc.rootView swap.
//   When navigate() swaps main→detail or detail→log, SwiftUI computes a new ideal
//   size. NSPopover sees contentSize change → re-anchors X+Y → left-jump.
//   This was v0.25's mistake.
//   ❌ NEVER set sizingOptions = .preferredContentSize
//
// ── THE LEFT-JUMP RULE (#52 #54) ─────────────────────────────────────────────
//   macOS re-anchors NSPopover to the status bar button every time contentSize
//   changes while the popover is VISIBLE. That re-anchor IS the left-jump.
//   contentSize and setFrameSize are FORBIDDEN while popover.isShown == true.
//
// ── THE HEIGHT-FITS-CONTENT RULE (#57) ───────────────────────────────────────
//   Height is read via fittingSize.height in openPopover() each time it is called.
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
//     ✔ hc.rootView = mainView() via async dispatch (popover already closed, safe)
//     ✖ reload() ← objectWillChange → .transient treats as outside-click → thrash loop
//     ✖ contentSize ← avoid even during close — timing is ambiguous
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
//   ❌ add size changes in navigate() → popover is open → left-jump
//   ❌ add size changes in onChange → popover may be open → left-jump
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
    //   but the guard is still correct to prevent unnecessary re-renders.
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
        // ❌ NEVER set sizingOptions = [] explicitly (same as default, but signals intent incorrectly)
        let hc = NSHostingController(rootView: mainView())
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        hc.view.frame = NSRect(origin: .zero, size: initialSize)
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient   // closes on outside click
        popover.animates              = false         // avoids animation triggering size reads
        popover.contentSize           = initialSize
        popover.contentViewController = hc
        popover.delegate              = self
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            // ⚠️ EXACTLY TWO OPERATIONS. NEVER ADD A THIRD. NEVER TOUCH SIZE.
            // Fires every ~10s. popoverIsOpen guard prevents re-render while visible.
            // Any size change here = left-jump (popover may be visible).
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ⚠️ CAUSE 2: guard prevents SwiftUI re-render while popover is open.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: — NSPopoverDelegate

    // ⚠️ CAUSE 3: ONLY set flag + async rootView reset here.
    // ❌ NEVER call reload() from popoverDidClose — fires objectWillChange →
    //   .transient treats as outside-click → open/close thrash loop.
    //
    // The async rootView reset ensures that when the user re-opens the popover,
    // hc.rootView is always mainView() so openPopover() reads the correct
    // fittingSize (mainView height, not detailView or logView height).
    // The reset is async so it fires after the popover close animation completes.
    // It is safe because the popover is already closed — no re-anchor is possible.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false  // ❌ NEVER add reload() or contentSize here
        // Reset to level 1 so next open always measures mainView fittingSize.
        // Async dispatch: popover close animation may still be running synchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hc?.rootView = self.mainView()
        }
    }

    // MARK: — View factories

    // mainView() — navigation level 1.
    // onSelectJob navigates to level 2 (detailView).
    private func mainView() -> AnyView {
        AnyView(PopoverMainView(store: observable, onSelectJob: { [weak self] job in
            guard let self else { return }
            self.navigate(to: self.detailView(job: job))
        }))
    }

    // detailView(job:) — navigation level 2.
    // onBack navigates back to level 1 (mainView).
    // onSelectStep navigates forward to level 3 (logView).
    //
    // The callbacks use [weak self] to avoid retain cycles. AppDelegate owns the
    // popover and hc; if AppDelegate were deallocated, the closure guard would
    // prevent a crash. In practice AppDelegate lives for the app's lifetime.
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

    // logView(job:step:) — navigation level 3.
    // onBack navigates back to level 2 (detailView for the same job).
    // job is captured by value in the closure — ActiveJob is a struct, so this
    // is a safe copy; no reference cycle or stale-pointer risk.
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

    // ═══════════════════════════════════════════════════════════════════════════
    // ⚠️ ARCHITECTURE 2 REGRESSION GUARD — navigate() INVARIANTS
    // Full specification: status-bar-app-position-warning.md §4 (Architecture 2)
    // Related issues: #52 #54 #57 #375 #376 #377
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // THIS FUNCTION MUST CONTAIN EXACTLY ONE LINE OF CODE: hc?.rootView = view
    //
    // navigate() is called while the popover IS open (isShown == true).
    // NSPopover re-anchors its position from scratch any time contentSize changes
    // while shown — even a height-only change causes a full X+Y re-anchor, which
    // moves the popover to the far left of the screen. This is documented AppKit
    // behaviour with no override API. See status-bar-app-position-warning.md §1.
    //
    // Architecture 2 invariants that MUST hold at this call site:
    //
    //   ✅ hc?.rootView = view          — the ONLY permitted operation
    //   ❌ popover?.contentSize = …     — LEFT-JUMP: re-anchors while shown
    //   ❌ hc?.view.setFrameSize(…)     — LEFT-JUMP: re-anchors while shown
    //   ❌ hc?.sizingOptions = …        — must remain default [] at all times
    //   ❌ popover?.performClose() + show() for navigation — show() re-anchors
    //   ❌ DispatchQueue.main.async { contentSize } — still fires while shown
    //   ❌ NSAnimationContext { contentSize } — still fires while shown
    //   ❌ ANY call to remeasurePopover() or fittingSize reads — LEFT-JUMP
    //
    // The rootView swap triggers SwiftUI's in-place diffing mechanism.
    // SwiftUI redraws the new view tree inside the EXISTING frame with NO
    // notification to NSPopover — contentSize is untouched, no re-anchor occurs.
    //
    // Height contract after navigation:
    //   The popover frame was sized in openPopover() from mainView()'s fittingSize.
    //   Detail and log views MUST use ScrollView to handle content that overflows
    //   this frame. The frame is intentionally fixed for the session — accept it.
    //   Do NOT attempt to resize after show(). That is the oscillation trap
    //   documented in status-bar-app-position-warning.md §3.
    //
    // ═══════════════════════════════════════════════════════════════════════════
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
    // This gives correct dynamic height every open without the continuous
    // re-reading that preferredContentSize does. No re-anchor risk.
    //
    // ⚠️ CAUSE 4: ORDER IS NON-NEGOTIABLE:
    //   Step 1: popoverIsOpen = true
    //     The guard must be live BEFORE reload() fires, otherwise onChange (which
    //     can fire at any time on the main thread) might sneak in a reload() call
    //     between now and show(), causing a SwiftUI re-render that shifts fittingSize.
    //   Step 2: observable.reload()
    //     Feeds fresh data into SwiftUI so fittingSize reflects current job count.
    //   Step 3: read fittingSize
    //     Must come AFTER reload() so the measured height is up-to-date.
    //     fittingSize.width comes from .frame(idealWidth: 340) in PopoverMainView.
    //     fittingSize.height comes from the VStack's intrinsic content height.
    //   Step 4: setFrameSize + contentSize
    //     Safe only because isShown==false is guaranteed at this point.
    //   Step 5: show()
    //     Must come LAST. After this line popover.isShown==true and no sizing is allowed.
    //
    // ⚠️ DO NOT reassign hc.rootView here.
    //   Reassigning rootView discards the SwiftUI tree and builds a new one.
    //   SwiftUI defers layout to the next run-loop tick → fires AFTER show() → left-jump.
    //   hc.rootView is always mainView() here because:
    //     • Initialised as mainView() in applicationDidFinishLaunching.
    //     • popoverDidClose resets it to mainView() asynchronously after each close.
    //     • .transient closes on outside-click before user can re-open while on level 2/3.
    //
    // ❌ NEVER read fittingSize before reload() — stale data = wrong height
    // ❌ NEVER remove .frame(idealWidth: 340) from PopoverMainView — fittingSize.width = 0
    // ❌ NEVER resize after show() — left-jump
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc else { return }

        popoverIsOpen = true              // ❌ Step 1: NEVER move below reload()
        observable.reload()               // ❌ Step 2: NEVER move above popoverIsOpen = true

        let size = NSSize(
            width:  hc.view.fittingSize.width > 0 ? hc.view.fittingSize.width : Self.fixedWidth,
            height: hc.view.fittingSize.height    // Step 3: read AFTER reload()
        )

        hc.view.setFrameSize(size)        // Step 4a: safe — isShown==false
        popover.contentSize = size        // Step 4b: safe — isShown==false

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)  // Step 5
        popover.contentViewController?.view.window?.makeKey()
        // ⚠️ NOTHING after show(). isShown==true from here. Any size change = left-jump.
    }
}
