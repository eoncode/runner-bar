import AppKit
import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v2.4
//
// ============================================================
// SECTION 1: HOW NSPopover SIZING WORKS
// ============================================================
//
// NSPopover reads preferredContentSize from NSHostingController.
// With sizingOptions = .preferredContentSize, SwiftUI automatically
// updates this from the view's IDEAL size.
//
// ANY change to preferredContentSize — even 1pt, even height-only —
// causes NSPopover to re-anchor its FULL screen position (X AND Y).
// A wrong width sends the popover to the far left. ("left jump")
//
// ============================================================
// SECTION 2: THE DYNAMIC HEIGHT STRATEGY (v2.4)
// ============================================================
//
// PROBLEM (CAUSE 8): jobListView has dynamic height (~300–480pt).
// JobStepsView is always 480pt. Navigating jobList→steps while the
// popover is OPEN changes preferredContentSize.height → re-anchor →
// left jump.
//
// SOLUTION: Ensure preferredContentSize NEVER changes while the
// popover is visible:
//
//   1. sizingOptions = .preferredContentSize (auto-sizing ON, v2.4)
//      fittingSize (v2.2–2.3) is unusable before the view has a
//      window — it always returns the minimum floor (120pt).
//
//   2. navState is ALWAYS .jobList when the popover opens.
//      → AppDelegate resets it to .jobList in popoverWillShow (before
//        SwiftUI renders), so the view never opens mid-navigation.
//
//   3. Navigating jobList → steps is allowed (height increases: e.g.
//      300→480pt). The re-anchor from THIS direction sends the popover
//      UP (taller), which does NOT cause a left-jump — only width
//      changes cause the far-left symptom.
//      NOTE: height increase does move the popover vertically. To
//      avoid that too, JobStepsView onBack calls popover.performClose()
//      instead of setting navState=.jobList directly — so the height
//      never DECREASES while visible.
//
//   4. Therefore: height only ever stays the same or increases while
//      the popover is open. It resets on close. No left jump ever.
//
// ============================================================
// SECTION 3: ALL ROOT CAUSES OF LEFT-JUMP
// ============================================================
//
// CAUSE 1 — .frame(width:340) instead of .frame(idealWidth:340)
//   Fix: Use idealWidth on root Group. maxWidth:.infinity on children.
//
// CAUSE 2 — reload() called while popover is open
//   Fix: Guard with `if !popoverIsOpen`.
//
// CAUSE 3 — reload() called from popoverDidClose
//   Fix: Never call reload() from popoverDidClose.
//
// CAUSE 4 — popoverIsOpen set AFTER reload() in togglePopover
//   Fix: Set popoverIsOpen=true FIRST, then reload(), then show().
//
// CAUSE 5 — Multiple @Published properties causing multiple renders
//   Fix: Single StoreState struct. One assignment = one render.
//
// CAUSE 6 — onChange reload races with togglePopover show()
//   Fix: Defer show() with DispatchQueue.main.async.
//
// CAUSE 7 — Async step load fires @State change after appear
//   Fix: Steps pre-fetched before navState changes.
//
// CAUSE 8 — Height change during navigation (jobList→steps→jobList)
//   Fix: navState reset to .jobList before popover opens (popoverWillShow).
//        onBack closes the popover instead of navigating back directly.
//        Height only ever increases (never decreases) while visible.
//
// ============================================================
// SECTION 4: FORBIDDEN ACTIONS
// ============================================================
//
//   ✘ reload() unconditionally in onChange                      => CAUSE 2
//   ✘ reload() from popoverDidClose                            => CAUSE 3
//   ✘ popoverIsOpen=true AFTER reload() in togglePopover       => CAUSE 4
//   ✘ Multiple @Published properties in RunnerStoreObservable  => CAUSE 5
//   ✘ show() outside DispatchQueue.main.async                  => CAUSE 6
//   ✘ Async step load inside JobStepsView                      => CAUSE 7
//   ✘ onBack setting navState=.jobList directly (use close)    => CAUSE 8
//   ✘ sizingOptions = []                                       => fittingSize=120 (broken without window)
//   ✘ popover.contentSize set anywhere                         => re-anchor
//   ✘ KVO on preferredContentSize                              => feedback loop
//   ✘ popover.animates = true                                  => re-anchor every frame
//
// ============================================================
// SECTION 5: ALLOWED
// ============================================================
//
//   ✔ sizingOptions = .preferredContentSize
//   ✔ Reset navState=.jobList in popoverWillShow (before render)
//   ✔ onBack calls popover.performClose() — user reopens to jobList
//   ✔ Height increase during jobList→steps navigation (no left jump)
//   ✔ reload() in togglePopover after popoverIsOpen=true
//   ✔ Defer show() with DispatchQueue.main.async
//   ✔ popoverIsOpen=false in popoverDidClose
//
// ============================================================
// SECTION 6: VERIFICATION TESTS
// ============================================================
//
// Test 1 — Open: no jump, height = content height (compact if few jobs).
// Test 2 — Open with jobs, leave open 30s: no jump.
// Test 3 — Rapid open/close 10x: stable every time.
// Test 4 — Tap job row → steps view: no left jump (height may grow up).
// Test 5 — On steps view, tap back: popover closes. Reopen shows jobList.
// Test 6 — Close, wait for job count change, reopen: correct new height.
//
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ CAUSE 2 / CAUSE 4 / CAUSE 6 guard flag.
    // Set true BEFORE reload() in togglePopover.
    // Set false in popoverDidClose.
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
        // ⚠️ .preferredContentSize: SwiftUI drives popover size from ideal size.
        // DO NOT use sizingOptions=[] — fittingSize is unusable before view
        // has a window and always returns the minimum floor (120pt).
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentViewController = hc
        popover.delegate              = self
        // ⚠️ DO NOT set popover.contentSize. Every write re-anchors position.
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate > onChange - refreshing status icon")
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ⚠️ CAUSE 2 FIX. DO NOT REMOVE.
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }

        RunnerStore.shared.start()
    }

    // ⚠️⚠️⚠️ ORDER IS NOT NEGOTIABLE. CAUSES 4, 5, 6. ⚠️⚠️⚠️
    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            log("AppDelegate > opening popover")
            popoverIsOpen = true          // STEP 1: arm guard (CAUSE 4)
            observable.reload()           // STEP 2: one publish (CAUSE 5)
            DispatchQueue.main.async { [weak self] in   // STEP 3: drain publish (CAUSE 6)
                guard let self, let popover = self.popover,
                      let button = self.statusItem?.button else { return }
                guard !popover.isShown else { return }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            }
        }
    }

    // ⚠️ CAUSE 8 FIX: reset navState to .jobList BEFORE the popover
    // becomes visible. This fires before SwiftUI renders the first frame,
    // so preferredContentSize is always computed from jobListView on open.
    // Height starts at jobList height every time — no stale steps height.
    func popoverWillShow(_ notification: Notification) {
        log("AppDelegate > popoverWillShow — resetting navState to jobList")
        hc?.rootView.resetNavState()
    }

    func popoverDidClose(_ notification: Notification) {
        log("AppDelegate > popoverDidClose")
        popoverIsOpen = false
        // ⚠️⚠️⚠️ DO NOT call reload() here. CAUSE 3. ⚠️⚠️⚠️
    }
}
