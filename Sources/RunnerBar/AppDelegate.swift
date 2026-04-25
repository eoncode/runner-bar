import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  REGRESSION GUARD — READ THIS ENTIRE COMMENT BEFORE CHANGING ANYTHING
// ═══════════════════════════════════════════════════════════════════════════════
//
// This file was broken and rewritten 30+ times. The issues kept cycling because
// every fix for one bug re-introduced a different one. The solution requires
// ALL 5 root causes to be fixed simultaneously. Fixing fewer than 5 fails.
// See issue #59 for full documentation.
//
// ── ARCHITECTURE ────────────────────────────────────────────────────────────
//   sizingOptions = .preferredContentSize
//   NSHostingController reads SwiftUI's IDEAL size to drive popover height.
//   This works for both PopoverMainView and JobDetailView without manual
//   height computation. DO NOT revert to sizingOptions = [].
//
// ── CAUSE 1: frame contract ──────────────────────────────────────────────────
//   Root views MUST use .frame(idealWidth: 340) — NOT .frame(width: 340)
//   .frame(width:) sets layout width but does NOT set ideal width.
//   preferredContentSize reads ideal width. If idealWidth is not set,
//   the width fluctuates across views → re-anchor → left-jump.
//   Child nav views use .frame(maxWidth: .infinity) to fill without overriding.
//
// ── CAUSE 2: poll re-renders while popover is open ───────────────────────────
//   The background poll calls RunnerStore.onChange every ~10s.
//   onChange calls observable.reload() → objectWillChange.send() → SwiftUI
//   re-render → preferredContentSize shifts 1pt → NSPopover re-anchors
//   → left-jump every 10s while popover is visible.
//   FIX: guard all reload() calls with: if !popoverIsOpen
//
// ── CAUSE 3: reload() in popoverDidClose ─────────────────────────────────────
//   Calling reload() from popoverDidClose fires objectWillChange which
//   .transient popover treats as an outside-click → re-closes → thrash loop.
//   FIX: popoverDidClose sets popoverIsOpen = false ONLY. Nothing else.
//
// ── CAUSE 4: race condition on open ──────────────────────────────────────────
//   If reload() fires BEFORE popoverIsOpen = true, the SwiftUI re-render is
//   deferred to next runloop tick. It fires AFTER show() while popoverIsOpen
//   is still false → Cause 2 guard is bypassed → re-anchor → left-jump.
//   FIX: strict order: popoverIsOpen = true → reload() → show()
//
// ── CAUSE 5: double objectWillChange ─────────────────────────────────────────
//   Adding objectWillChange.send() to reload() causes TWO layout passes
//   (one from send(), one from @Published setters) → jump on second open.
//   FIX: reload() uses withAnimation(nil). NEVER add objectWillChange.send().
//
// ── ABSOLUTE NEVER LIST ───────────────────────────────────────────────────────
//   ❌ popover.contentSize = anything → ANY write re-anchors X+Y
//   ❌ sizingOptions = [] → defeats preferredContentSize height driving
//   ❌ .frame(width: 340) on root view → doesn't set ideal width
//   ❌ reload() from popoverDidClose → thrash loop
//   ❌ reload() before popoverIsOpen = true → race condition
//   ❌ objectWillChange.send() in reload() → double re-render
//   ❌ NavigationStack/NavigationView inside NSPopover → fights sizing
//   ❌ ZStack + .transition(.move) → collapses width, animates from screen edge
//
// ═══════════════════════════════════════════════════════════════════════════════

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ CAUSE 2+4 guard. Must be set to true BEFORE reload() on open.
    // See REGRESSION GUARD above — order is non-negotiable.
    private var popoverIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // ⚠️ CAUSE 1: sizingOptions = .preferredContentSize
        // NSHostingController reads SwiftUI ideal size to size the popover.
        // Root views MUST use .frame(idealWidth: 340) for this to work.
        // ❌ NEVER change to sizingOptions = []
        let hc = NSHostingController(rootView: mainView())
        hc.sizingOptions = .preferredContentSize  // ❌ NEVER change to []
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentViewController = hc
        popover.delegate              = self
        // ❌ NEVER set popover.contentSize — ANY write re-anchors X+Y position
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ⚠️ CAUSE 2: guard prevents re-render while popover is visible
            // Without this guard, every 10s poll causes a left-jump
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }
        RunnerStore.shared.start()
    }

    // MARK: — NSPopoverDelegate

    // ⚠️ CAUSE 3: ONLY set flag here. Never call reload() from popoverDidClose.
    // Calling reload() here fires objectWillChange → .transient treats as
    // outside-click → open/close thrash loop on every single click.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false  // ❌ NEVER add reload() here
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

    // ⚠️ rootView swap ONLY. Zero size changes.
    // navigate() fires while popover IS open (user tapped inside).
    // .transient only closes on clicks OUTSIDE — not taps inside.
    // preferredContentSize + idealWidth automatically adjusts height.
    // ❌ NEVER add contentSize, setFrameSize, or any size op here.
    private func navigate(to view: AnyView) {
        hc?.rootView = view  // ❌ NEVER add anything else here
    }

    // MARK: — Popover toggle

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }

        // ⚠️ CAUSE 4: ORDER IS ABSOLUTELY NON-NEGOTIABLE.
        //   Step 1: popoverIsOpen = true   (guard is live before reload fires)
        //   Step 2: observable.reload()    (triggers SwiftUI re-render with fresh data)
        //   Step 3: show()                 (shows with correct, stable size)
        //
        // If reload() fires before popoverIsOpen=true, the SwiftUI re-render
        // is deferred to next runloop tick, fires AFTER show() while flag is
        // still false → Cause 2 guard bypassed → left-jump on every open.
        popoverIsOpen = true              // ❌ NEVER move this below reload()
        observable.reload()               // ❌ NEVER move this above popoverIsOpen=true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
