import AppKit
import SwiftUI

// ============================================================
// ⚠️  WARNING — POPOVER SIZING CONTRACT — READ BEFORE EDITING
// ============================================================
// VERSION: v1.7
//
// NSPopover re-anchors its FULL screen position (X and Y) any time
// contentSize changes — even by 1pt, even height-only changes.
// There is NO AppKit API to update height without triggering a re-anchor.
//
// THREE INDEPENDENT CAUSES OF LEFT-JUMP — ALL must be fixed simultaneously:
//
// CAUSE 1 — SwiftUI frame contract (PopoverView / child views):
//   - Root Group must use .frame(idealWidth: 340) NOT .frame(width: 340)
//   - Child nav views must use .frame(maxWidth: .infinity, ...) NOT width: 340
//   - See PopoverView.swift for full contract details
//
// CAUSE 2 — observable.reload() while popover is open:
//   - Every poll cycle: RunnerStore.onChange => observable.reload()
//     => SwiftUI re-render => preferredContentSize changes (even 1pt)
//     => NSPopover re-anchors screen X position => left jump
//   - FIX: guard with !popoverIsOpen in onChange handler
//
// CAUSE 3 — observable.reload() inside popoverDidClose:
//   - reload() => objectWillChange.send() => NSPopover (behavior=.transient)
//     treats the SwiftUI re-render as an outside-click => immediately
//     closes the popover => rapid open/close loop => left-jump thrash
//   - FIX: NEVER call reload() from popoverDidClose
//
// CAUSE 4 — popoverIsOpen set AFTER reload() in togglePopover (v1.6 race):
//   - reload() fires objectWillChange.send() synchronously
//   - SwiftUI schedules a re-render on the next runloop
//   - popoverIsOpen = true is set AFTER reload() but the scheduled
//     re-render fires AFTER show() while popoverIsOpen is still false
//   - That re-render changes preferredContentSize => left jump
//   - FIX: set popoverIsOpen = true FIRST, then reload(), then show()
//     Now the onChange guard blocks any racing re-renders
//
// ⚠️  THINGS THAT WILL CAUSE LEFT-JUMP / THRASH REGRESSION:
//   ✗ Calling observable.reload() unconditionally in onChange (CAUSE 2)
//   ✗ Calling observable.reload() from popoverDidClose (CAUSE 3)
//   ✗ Setting popoverIsOpen = true AFTER reload() in togglePopover (CAUSE 4)
//   ✗ Setting popover.contentSize anywhere (even once at startup)
//   ✗ Removing or changing hc.sizingOptions
//   ✗ Adding KVO on preferredContentSize to manually update contentSize
//   ✗ Changing .frame(idealWidth:) to .frame(width:) in PopoverView
//   ✗ Using .frame(width: 340) in any child nav view
//
// ⚠️  THINGS THAT WILL CAUSE EMPTY-SPACE REGRESSION:
//   ✗ Removing .fixedSize(horizontal:false, vertical:true) from jobListView
//   ✗ Changing .frame(maxHeight: 480) to .frame(height: 480) on jobListView
//   ✗ Wrapping jobListView in a ScrollView
//
// This regression has been introduced 30+ times.
// See GitHub issues #53, #54, #58 before touching ANY of this.
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hc: NSHostingController<PopoverView>?
    private let observable = RunnerStoreObservable()

    // ⚠️ This flag suppresses observable.reload() while the popover is open.
    // It MUST be set to true BEFORE calling reload() in togglePopover.
    // If set after reload(), the objectWillChange publish races with show()
    // and the guard below doesn't block the resulting re-render => CAUSE 4.
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
        // ⚠️ DO NOT remove or change this line. See contract at top of file.
        // sizingOptions = .preferredContentSize + .frame(idealWidth:340) in PopoverView
        // together keep preferredContentSize.width locked at 340 across all nav states.
        hc.sizingOptions = .preferredContentSize
        self.hc = hc

        let popover = NSPopover()
        popover.behavior              = .transient
        popover.animates              = false
        popover.contentViewController = hc
        popover.delegate              = self
        // ⚠️ DO NOT set popover.contentSize here or anywhere else.
        // Any manual write to contentSize causes a full NSPopover re-anchor => left jump.
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate > onChange - refreshing status icon")
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)

            // ⚠️ CAUSE 2 FIX: only reload observable when popover is NOT open.
            // Calling reload() while visible => SwiftUI re-render => preferredContentSize
            // changes => NSPopover re-anchors full screen X position => left jump.
            // While closed: onChange fires freely and keeps observable current,
            // so the next open always shows fresh data after the pre-open reload().
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }

        RunnerStore.shared.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            log("AppDelegate > opening popover")
            // ⚠️ ORDER IS CRITICAL — DO NOT REORDER THESE THREE LINES.
            //
            // 1. Set popoverIsOpen = true FIRST.
            //    This arms the CAUSE 2 guard so that if reload() below
            //    fires objectWillChange and SwiftUI schedules a re-render
            //    that lands after show(), the onChange guard blocks it.
            //
            // 2. Call reload() SECOND — snapshots fresh data into observable.
            //    This is the ONLY place reload() should be called proactively.
            //    ⚠️ Do NOT move reload() to popoverDidClose — see CAUSE 3.
            //
            // 3. Call show() THIRD.
            popoverIsOpen = true
            observable.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        log("AppDelegate > popoverDidClose")
        popoverIsOpen = false
        // ⚠️ DO NOT call observable.reload() here — CAUSE 3.
        // Calling reload() from popoverDidClose triggers objectWillChange.send()
        // which NSPopover (behavior=.transient) treats as an outside-click event
        // and immediately re-closes the popover => open/close thrash => left jump.
        // The onChange handler keeps data current while the popover is closed.
        // Fresh data is loaded in togglePopover before the next show().
    }
}
