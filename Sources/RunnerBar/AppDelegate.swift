import AppKit
import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v1.9
//
// This file controls a brutally fragile relationship between SwiftUI,
// NSHostingController, and NSPopover. The symptom when broken is that
// the popover flies to the far left of the screen every time it opens
// or every time the background poll fires. It looks like a trivial
// layout bug. It is NOT. It took 30+ attempts across a single day to
// fully identify all root causes.
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
// height-only changes — causes NSPopover to re-anchor its FULL screen
// position (both X and Y). There is NO AppKit API to change height
// without triggering a position re-anchor. This is undocumented AppKit
// behavior discovered through painful trial and error.
//
// The re-anchor recalculates where the arrow should point on the status
// bar button. Since the status bar button is on the RIGHT side of the
// screen, a wrong preferredContentSize.width places the popover's LEFT
// edge far to the LEFT of the screen. This is the "left jump" symptom.
//
// ============================================================
// SECTION 2: ALL 6 ROOT CAUSES OF LEFT-JUMP (ALL must be fixed)
// ============================================================
//
// CAUSE 1 — Wrong SwiftUI frame modifier on root or child views
//   Location: PopoverView.swift, JobStepsView.swift, MatrixGroupView.swift
//   What happens: .frame(width: 340) in any view overrides the ideal
//   width computation. When SwiftUI navigates between states, the
//   preferredContentSize.width fluctuates => NSPopover re-anchors.
//   Fix: .frame(idealWidth: 340) on root Group only.
//        .frame(maxWidth: .infinity, ...) on all child nav views.
//   See: PopoverView.swift SECTION 1 for full frame contract.
//
// CAUSE 2 — Calling observable.reload() while the popover is open
//   Location: onChange handler in this file
//   What happens: The background RunnerStore poll fires every ~10s.
//   Each poll calls onChange => observable.reload() => objectWillChange
//   => SwiftUI re-renders => preferredContentSize changes => re-anchor
//   => popover jumps left while the user is looking at it.
//   Fix: Guard with `if !self.popoverIsOpen`.
//
// CAUSE 3 — Calling observable.reload() from popoverDidClose
//   Location: popoverDidClose in this file
//   What happens: reload() fires objectWillChange. NSPopover with
//   behavior = .transient treats this as an outside-click and immediately
//   re-closes — creating a rapid open/close/open/close thrash loop.
//   Fix: NEVER call reload() from popoverDidClose. Not ever.
//
// CAUSE 4 — popoverIsOpen flag set AFTER reload() in togglePopover
//   Location: togglePopover in this file
//   What happens: reload() fires objectWillChange synchronously.
//   SwiftUI schedules the re-render for the next runloop tick.
//   If popoverIsOpen is still false when that re-render fires (because
//   it was set AFTER reload()), the CAUSE 2 guard doesn't block it.
//   The re-render changes preferredContentSize AFTER show() => jump.
//   Fix: Set popoverIsOpen = true FIRST, then reload(), then show().
//   DO NOT REORDER THESE THREE LINES.
//
// CAUSE 5 — Multiple objectWillChange publishes per reload()
//   Location: RunnerStoreObservable in PopoverView.swift
//   What happens (v1.7): Two separate @Published properties (runners, jobs)
//   each fired objectWillChange automatically => 2 publishes per reload().
//   Plus an explicit .send() => 3 publishes. Three re-renders per reload().
//   Even with CAUSE 4 fixed, these re-renders race against show() or
//   against NSPopover.transient dismissal logic.
//   Fix (v1.9): Merged into ONE @Published StoreState struct.
//   ONE assignment = ONE Combine publish = ONE re-render. Atomic.
//   See: RunnerStoreObservable in PopoverView.swift for full history.
//
// CAUSE 6 — onChange-triggered reload races with togglePopover-triggered reload
//   Location: onChange handler + togglePopover in this file
//   What happens: onChange fires (popoverIsOpen=false) => reload() queues
//   a Combine publish on the runloop. Before that publish drains, the user
//   clicks the icon. togglePopover runs: popoverIsOpen=true, reload() again
//   (second publish in flight), show(). Now TWO objectWillChange events are
//   in-flight simultaneously. NSPopover(.transient) sees the second pending
//   publish as an outside-click => immediately calls popoverDidClose.
//   Symptom: popover opens and immediately closes on every click.
//   Fix: Defer show() to the next runloop tick with DispatchQueue.main.async.
//   This gives any in-flight Combine publishes from the onChange reload()
//   time to drain completely before show() is called. By the time the
//   async block runs, the runloop is clear of pending objectWillChange events.
//   DO NOT remove the DispatchQueue.main.async wrapping show().
//   DO NOT move show() back outside the async block.
//
// ============================================================
// SECTION 3: COMPLETE FORBIDDEN ACTIONS LIST
// ============================================================
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
//   ✘ Split StoreState back into separate @Published properties
//       => CAUSE 5: multiple publishes per reload() => multiple re-renders
//
//   ✘ Add objectWillChange.send() anywhere in RunnerStoreObservable
//       => Extra publish => extra re-render => re-anchor
//
//   ✘ Move show() outside the DispatchQueue.main.async block
//       => CAUSE 6: onChange reload races with togglePopover => immediate close
//
//   ✘ Set popover.contentSize anywhere in this file or any other
//       => NSPopover immediately re-anchors => left jump
//
//   ✘ Remove hc.sizingOptions = .preferredContentSize
//       => NSHostingController stops syncing => wrong size entirely
//
//   ✘ Add KVO observer on preferredContentSize
//       => Feedback loop: size change => KVO => set contentSize => re-anchor
//
//   ✘ Change popover.animates = false to true
//       => Animation interpolates contentSize => re-anchor every frame
//
// ============================================================
// SECTION 4: WHAT IS ALLOWED
// ============================================================
//
//   ✔ Update statusItem button image in onChange (no size impact)
//   ✔ Call reload() inside togglePopover AFTER popoverIsOpen = true
//   ✔ Defer show() with DispatchQueue.main.async (required for CAUSE 6)
//   ✔ Set popoverIsOpen = false in popoverDidClose (flag only, no reload)
//   ✔ Read popover.isShown freely
//   ✔ Call popover.performClose()
//
// ============================================================
// SECTION 5: HOW TO VERIFY THE FIX IS STILL WORKING
// ============================================================
//
// Test 1 — Open with no active jobs. Popover must NOT jump.
// Test 2 — Close. Wait for a job to appear (poll fires, state changes
//          0 jobs → 1 job). Reopen. Popover must NOT jump or immediately close.
//          THIS IS THE HARDEST TEST. It was the regression scenario in v1.7-v1.8.
// Test 3 — Open and leave open for 30+ seconds (3+ poll cycles).
//          Popover must NOT jump while open.
// Test 4 — Rapidly open/close 10 times.
//          Must open stably every time. No thrash or immediate-close.
// Test 5 — Navigate to JobStepsView and back.
//          Width must stay 340pt. No jump on navigation.
//
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ CRITICAL FLAG — participates in CAUSE 2, CAUSE 4, and CAUSE 6 fixes.
    // MUST be set to true BEFORE calling observable.reload() in togglePopover.
    // MUST be set to false in popoverDidClose.
    // DO NOT use popover.isShown as a substitute — it is unreliable during
    // the open/close transition. Use this flag exclusively.
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
        // .preferredContentSize + .frame(idealWidth:340) in PopoverView
        // together lock preferredContentSize.width = 340 at all times.
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()
        // ⚠️ behavior = .transient is required for standard macOS menu-bar UX.
        // WARNING: .transient means any objectWillChange publish that fires
        // while NSPopover is processing show() can trigger auto-dismiss.
        // This is why CAUSE 3 and CAUSE 6 are so dangerous.
        popover.behavior              = .transient
        // ⚠️ animates = false prevents size-interpolation re-anchors during open.
        popover.animates              = false
        popover.contentViewController = hc
        popover.delegate              = self
        // ⚠️ DO NOT set popover.contentSize here or anywhere else.
        // Any write to contentSize triggers a full position re-anchor.
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate > onChange - refreshing status icon")
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)

            // ⚠️ CAUSE 2 FIX — DO NOT REMOVE THIS GUARD.
            // reload() while popover is open => re-render => preferredContentSize
            // changes => NSPopover re-anchors => left jump.
            // While closed: reload freely to keep data current for next open.
            // DO NOT replace with `if !self.popover?.isShown ?? false`.
            // popover.isShown is unreliable during transitions.
            //
            // ⚠️ CAUSE 6 NOTE: Even though this guard prevents reload() while open,
            // a reload() that fires here while closed can queue a Combine publish
            // that hasn't drained yet when the user clicks the icon. This is why
            // show() in togglePopover is wrapped in DispatchQueue.main.async —
            // to let this pending publish drain before show() runs.
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }

        RunnerStore.shared.start()
    }

    // ⚠️⚠️⚠️  THE ORDER OF OPERATIONS IN THIS METHOD IS NOT NEGOTIABLE  ⚠️⚠️⚠️
    // See SECTION 2 CAUSE 4 and CAUSE 6 for full explanation.
    //
    // REQUIRED ORDER:
    //   1. popoverIsOpen = true          (arm CAUSE 2 guard synchronously)
    //   2. observable.reload()           (snapshot fresh data, fires 1 publish)
    //   3. DispatchQueue.main.async {    (defer show to next runloop tick)
    //        popover.show(...)           (show only after all publishes drained)
    //      }
    //
    // WHY THE ASYNC DEFER:
    //   reload() fires objectWillChange which schedules a SwiftUI re-render
    //   for the next runloop tick. If the user clicked the icon immediately
    //   after an onChange-triggered reload() (which also queued a publish),
    //   there may be TWO pending publishes when we reach show().
    //   NSPopover(.transient) sees the second pending publish as an outside-
    //   click and immediately calls popoverDidClose.
    //   By deferring show() one tick, ALL pending publishes drain and complete
    //   their re-renders before show() executes. Clean runloop = stable open.
    //
    // DO NOT move show() outside the async block.
    // DO NOT remove the DispatchQueue.main.async.
    // DO NOT reorder steps 1, 2, 3.
    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            log("AppDelegate > opening popover")

            // STEP 1: Arm the CAUSE 2 guard FIRST, synchronously.
            // This prevents any onChange poll that fires between now and show()
            // from calling reload() and queueing another publish.
            popoverIsOpen = true

            // STEP 2: Snapshot fresh data. Fires exactly ONE objectWillChange
            // publish (via single @Published StoreState — see CAUSE 5 fix).
            observable.reload()

            // STEP 3: Defer show() to the NEXT runloop tick.
            // This gives the publish from step 2 (and any publish still draining
            // from a pre-click onChange reload) time to complete their SwiftUI
            // re-render pass before NSPopover.show() is called.
            // When this async block executes, the runloop is clear of pending
            // objectWillChange events => NSPopover(.transient) won't auto-dismiss.
            DispatchQueue.main.async { [weak self] in
                guard let self, let popover = self.popover,
                      let button = self.statusItem?.button else { return }
                // Re-check isShown: user may have clicked again during the async delay.
                guard !popover.isShown else { return }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            }
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        log("AppDelegate > popoverDidClose")
        popoverIsOpen = false

        // ⚠️⚠️⚠️  DO NOT ADD observable.reload() HERE. EVER.  ⚠️⚠️⚠️
        // This is CAUSE 3. reload() => objectWillChange => NSPopover (.transient)
        // treats it as outside-click => immediately re-closes => thrash loop.
        // Data stays current via onChange. Fresh data is loaded in togglePopover.
    }
}
