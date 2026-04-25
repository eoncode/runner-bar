import AppKit
import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v1.7
//
// This file controls a brutally fragile relationship between SwiftUI,
// NSHostingController, and NSPopover. The symptom when broken is that
// the popover flies to the far left of the screen every time it opens
// or every time the background poll fires. It looks like a trivial
// layout bug. It is NOT. It took 30+ attempts to fully fix.
//
// If you are an AI assistant or a future developer reading this:
// DO NOT "simplify" this code. DO NOT "clean it up". DO NOT move
// lines around. DO NOT remove comments. Every single constraint here
// exists because its absence caused a regression that was extremely
// hard to diagnose and fix.
//
// ============================================================
// SECTION 1: HOW NSPopover SIZING ACTUALLY WORKS
// ============================================================
//
// NSPopover does NOT size itself from contentViewController.view.frame.
// It sizes itself from contentViewController.preferredContentSize.
//
// NSHostingController (which IS our contentViewController) automatically
// updates preferredContentSize from the SwiftUI view's IDEAL size when
// sizingOptions = .preferredContentSize.
//
// KEY INSIGHT: ANY change to preferredContentSize — even 1 point, even
// height-only — causes NSPopover to re-anchor its FULL screen position
// (both X and Y). There is NO AppKit API to change height without
// triggering a position re-anchor. This is undocumented AppKit behavior
// discovered through painful trial and error.
//
// The re-anchor recalculates where the arrow should point on the status
// bar button. Since the status bar button is on the RIGHT side of the
// screen, a wrong preferredContentSize.width calculation places the
// popover's LEFT edge far to the LEFT of the screen. This is the
// "left jump" symptom.
//
// ============================================================
// SECTION 2: ALL 4 ROOT CAUSES OF LEFT-JUMP (ALL must be fixed)
// ============================================================
//
// CAUSE 1 — Wrong SwiftUI frame modifier on root or child views
//   Location: PopoverView.swift, JobStepsView.swift, MatrixGroupView.swift
//   What happens: .frame(width: 340) in any view overrides the ideal
//   width computation. When SwiftUI navigates between states, the
//   preferredContentSize.width fluctuates between the fixed value and
//   the ideal value — NSPopover re-anchors on every navigation.
//   Fix: .frame(idealWidth: 340) on root Group only.
//        .frame(maxWidth: .infinity, ...) on all child nav views.
//   See: PopoverView.swift SECTION 3 for full frame contract.
//
// CAUSE 2 — Calling observable.reload() while the popover is open
//   Location: onChange handler in this file
//   What happens: The background RunnerStore poll fires every ~10s.
//   Each poll calls onChange => observable.reload() => objectWillChange
//   .send() => SwiftUI re-renders => preferredContentSize changes by
//   even 1pt (font metrics, content differences) => NSPopover re-anchors
//   => popover jumps left while the user is looking at it.
//   Fix: Guard with `if !self.popoverIsOpen` so reload() is suppressed
//   while the popover is visible. The onChange still updates the status
//   bar icon — only the observable reload is blocked.
//
// CAUSE 3 — Calling observable.reload() from popoverDidClose
//   Location: popoverDidClose in this file
//   What happens: reload() calls objectWillChange.send(). NSPopover with
//   behavior = .transient listens for ANY window activity and dismisses
//   itself in response. An objectWillChange publish during the close
//   sequence is treated as an outside-click event, causing NSPopover to
//   immediately re-close — even if it was already in the process of
//   opening again. This creates a rapid open/close/open/close thrash
//   loop. Every click on the status bar icon opens and immediately closes
//   the popover. Looks identical to a left-jump from the user’s perspective.
//   Fix: NEVER call reload() from popoverDidClose. Not ever. Not even
//   "just a quick reload". The onChange handler keeps data current while
//   closed. The pre-open reload() in togglePopover gives fresh data.
//
// CAUSE 4 — popoverIsOpen flag set AFTER reload() in togglePopover
//   Location: togglePopover in this file
//   What happens: reload() calls objectWillChange.send() synchronously.
//   SwiftUI does NOT re-render synchronously — it schedules the re-render
//   for the next runloop tick. If popoverIsOpen is still false when that
//   re-render fires (because it was set AFTER reload()), the CAUSE 2
//   guard does NOT block it. The re-render changes preferredContentSize
//   AFTER show() has been called. NSPopover re-anchors. Left jump.
//   Fix: The order in togglePopover MUST be:
//     1. popoverIsOpen = true   ← arm the guard FIRST
//     2. observable.reload()   ← safe to publish now, guard is armed
//     3. popover.show()        ← popover opens with stable size
//   DO NOT REORDER THESE THREE LINES.
//
// ============================================================
// SECTION 3: COMPLETE FORBIDDEN ACTIONS LIST
// ============================================================
//
// The following changes WILL cause the left-jump to return.
// Each one has been tried. Each one broke things. DO NOT DO THEM:
//
//   ✘ Call observable.reload() unconditionally in onChange
//       => CAUSE 2: jump every poll cycle while popover is open
//
//   ✘ Call observable.reload() from popoverDidClose
//       => CAUSE 3: open/close thrash loop on every click
//
//   ✘ Set popoverIsOpen = true AFTER reload() in togglePopover
//       => CAUSE 4: jump on first open due to runloop race
//
//   ✘ Set popover.contentSize anywhere in this file or any other
//       => NSPopover immediately re-anchors full position => left jump
//       => This includes setting it "just once at startup" or
//          "only to the current size". Even a no-op write triggers it.
//
//   ✘ Remove hc.sizingOptions = .preferredContentSize
//       => NSHostingController stops syncing preferredContentSize
//          from SwiftUI ideal size => popover gets wrong size entirely
//
//   ✘ Add KVO observer on preferredContentSize to "manually sync"
//       => Creates a feedback loop: size change => KVO fires => you set
//          contentSize => re-anchor => size change => infinite loop
//
//   ✘ Change popover.animates = false to true
//       => Animation interpolates contentSize through intermediate values
//          => re-anchor fires at every animation frame => jump visible
//          as a slide-to-left animation instead of instant jump
//
//   ✘ Use popover.behavior = .applicationDefined
//       => Popover no longer auto-closes on outside click, which sounds
//          useful but means the close/open lifecycle changes and CAUSE 3
//          may reappear differently
//
// ============================================================
// SECTION 4: WHAT IS ALLOWED
// ============================================================
//
//   ✔ Update statusItem button image in onChange (fine, no size impact)
//   ✔ Call observable.reload() inside togglePopover BEFORE show(),
//     as long as popoverIsOpen = true has already been set above it
//   ✔ Set popoverIsOpen = false in popoverDidClose (just the flag, no reload)
//   ✔ Read popover.isShown freely
//   ✔ Call popover.performClose() — this triggers popoverDidClose normally
//
// ============================================================
// SECTION 5: HOW TO VERIFY THE FIX IS STILL WORKING
// ============================================================
//
// 1. Run the app with a job actively in progress.
// 2. Open the popover. Leave it open for 30+ seconds (covers 3+ poll cycles).
//    => Popover must NOT jump or resize while open.
// 3. Close and re-open the popover rapidly 10 times.
//    => Popover must open stably every time, no thrash, no instant-close.
// 4. While popover is open, navigate to JobStepsView and back.
//    => Width must remain 340pt. No jump.
// 5. Open the popover when no jobs are running, then when a job starts.
//    => The transition from "no jobs" to "1 job" must not jump.
//
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ CRITICAL FLAG — read SECTION 2 CAUSE 2 and CAUSE 4 before touching.
    //
    // This flag has TWO jobs:
    //   Job A: Suppress observable.reload() in onChange while popover is open (CAUSE 2).
    //   Job B: Ensure any runloop-deferred SwiftUI re-render from reload() in
    //          togglePopover is also suppressed if it lands after show() (CAUSE 4).
    //
    // SET TO TRUE:  in togglePopover, BEFORE calling observable.reload()
    // SET TO FALSE: in popoverDidClose, after popover is fully closed
    //
    // If you set it to true AFTER reload() instead of before, CAUSE 4 bites you.
    // If you never set it at all, CAUSE 2 bites you every 10 seconds.
    private var popoverIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate > applicationDidFinishLaunching")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hc = NSHostingController(rootView: PopoverView(store: observable))

        // ⚠️ DO NOT REMOVE OR CHANGE THIS LINE.
        // .preferredContentSize tells NSHostingController to continuously
        // update its preferredContentSize from the SwiftUI view’s ideal size.
        // Without this, NSHostingController uses a fixed size and the popover
        // never resizes to fit content at all.
        // With this + .frame(idealWidth: 340) in PopoverView, width is
        // locked to 340pt across ALL navigation states. This is the
        // foundation of the entire left-jump fix.
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()

        // ⚠️ behavior = .transient: popover closes on outside click.
        // This is required for normal macOS menu-bar-app UX.
        // WARNING: .transient also means NSPopover watches for ANY window
        // activity and will auto-dismiss. This is why CAUSE 3 is so
        // dangerous — an objectWillChange publish counts as "activity".
        popover.behavior              = .transient

        // ⚠️ animates = false: disables NSPopover’s built-in size-change animation.
        // If true, contentSize is interpolated through intermediate values
        // during the animation, triggering multiple re-anchors per open.
        popover.animates              = false

        popover.contentViewController = hc
        popover.delegate              = self

        // ⚠️ DO NOT SET popover.contentSize HERE OR ANYWHERE ELSE IN THIS APP.
        // There is no popover.contentSize = ... line here and there must never
        // be one. Any write to contentSize — even setting it to the current
        // value — triggers a full NSPopover position re-anchor => left jump.
        // The size is entirely managed by preferredContentSize via sizingOptions.

        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate > onChange - refreshing status icon")

            // Updating the status bar icon image is always safe.
            // NSStatusItem image changes do not affect NSPopover sizing.
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)

            // ⚠️ CAUSE 2 FIX — DO NOT REMOVE THIS GUARD.
            //
            // observable.reload() calls objectWillChange.send() which triggers
            // a SwiftUI re-render which changes preferredContentSize which causes
            // NSPopover to re-anchor its full screen position => left jump.
            //
            // While the popover is closed, this is fine — reload freely so data
            // stays current and the next open shows fresh data immediately.
            //
            // While the popover is open, reload() is COMPLETELY BLOCKED.
            // The user sees a stable snapshot of data from when they opened it.
            // This is intentional and correct UX for an inspection popover.
            //
            // DO NOT change this to `if !self.popover?.isShown ?? false`.
            // popover.isShown is not reliable during the open/close transition.
            // popoverIsOpen is our own flag, set at the correct moment in
            // togglePopover BEFORE show() is called.
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }

        RunnerStore.shared.start()
    }

    // ⚠️⚠️⚠️  THE ORDER OF OPERATIONS IN THIS METHOD IS NOT NEGOTIABLE  ⚠️⚠️⚠️
    //
    // See SECTION 2 CAUSE 4 for the full explanation.
    // The three lines inside the `else` branch MUST stay in this exact order:
    //   1. popoverIsOpen = true
    //   2. observable.reload()
    //   3. popover.show(...)
    //
    // Swapping 1 and 2 reintroduces CAUSE 4 (runloop race).
    // Moving reload() to popoverDidClose reintroduces CAUSE 3 (thrash loop).
    // Removing reload() here means the popover shows stale data.
    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            log("AppDelegate > opening popover")

            // STEP 1 — Arm the guard FIRST.
            // This ensures that if reload() (step 2) fires objectWillChange
            // and SwiftUI defers a re-render to the next runloop tick,
            // that re-render will be blocked by the !popoverIsOpen guard
            // in onChange even if it lands after show() (step 3).
            popoverIsOpen = true

            // STEP 2 — Snapshot fresh data into the observable.
            // This is the ONLY proactive call to reload() in the app.
            // It runs with popoverIsOpen already true, so the CAUSE 2
            // guard will block any racing re-renders from the next poll.
            observable.reload()

            // STEP 3 — Show the popover.
            // By this point: guard is armed, data is fresh, size is stable.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        log("AppDelegate > popoverDidClose")

        // Disarm the guard so onChange can resume updating the observable
        // while the popover is closed.
        popoverIsOpen = false

        // ⚠️⚠️⚠️  DO NOT ADD observable.reload() HERE. EVER.  ⚠️⚠️⚠️
        //
        // This is CAUSE 3. It has been added here "just to refresh the data
        // on close" multiple times. Each time it broke everything.
        //
        // Here is what happens when you add reload() here:
        //   1. User clicks status bar icon to open popover.
        //   2. popoverDidClose fires (from previous close) — unlikely but possible.
        //   3. OR: the close sequence itself triggers popoverDidClose.
        //   4. reload() => objectWillChange.send()
        //   5. NSPopover (behavior=.transient) sees the publish as window activity.
        //   6. NSPopover immediately re-closes.
        //   7. popoverDidClose fires again => reload() => close => infinite loop.
        //   8. User sees: popover flickers open and immediately closes on every click.
        //
        // The data does NOT need to be refreshed on close.
        // onChange fires every 10 seconds and keeps the observable current.
        // The pre-open reload() in togglePopover gives fresh data on next open.
        // There is zero reason to reload on close. Do not add it.
    }
}
