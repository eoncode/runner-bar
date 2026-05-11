import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  ARCHITECTURE: NSPanel (not NSPopover)
// ═══════════════════════════════════════════════════════════════════════════════
//
// NSPopover was replaced after 50+ commits failed to prevent its left-jump.
// Root cause: NSPopover re-anchors on ANY contentSize change while shown.
// There is no public API override for this behaviour.
//
// NSPanel solution: we own the window position.
//   - positionBelow(button:) places the panel once, arrow centred on button.
//   - updateHeight(_:) resizes in-place keeping the top edge fixed.
//   - No re-anchor is possible because we control the frame directly.
//
// See: status-bar-app-position-warning.md
//      issues #52 #54 #57 #375 #376 #377 #379 #380
//
// ── NAVIGATION ───────────────────────────────────────────────────────────────
//   Level 1: PopoverMainView   — job list + runner status
//   Level 2: JobDetailView     — step list for a selected job
//   Level 3: StepLogView       — log output for a selected step
//
//   navigate() swaps hc.rootView then calls updateHeight() — safe because
//   we own the position. This is the KEY difference from NSPopover.
//
// ── HEIGHT UPDATE SEQUENCE (openPanel / navigate) ────────────────────────────
//   1. hc.rootView = newView   (swap content)
//   2. DispatchQueue.main.async hop 1: SwiftUI commits new tree
//   3. DispatchQueue.main.async hop 2: SwiftUI finishes layout
//   4. read hc.view.fittingSize.height — now stable
//   5. panel.updateHeight(h) — resizes in-place, no jump
//
// ── SAFE OPERATIONS PER CALL SITE ────────────────────────────────────────────
//   navigate()   : rootView swap + async two-hop height update ✔
//   openPanel()  : positionBelow(button:contentHeight:)        ✔
//   panelDidClose: reset rootView to mainView() async          ✔
//   onChange     : icon update + guarded reload()              ✔
//
// ── ABSOLUTE NEVER LIST ──────────────────────────────────────────────────────
//   ❌ Reintroduce NSPopover — the jump cannot be fixed
//   ❌ reload() from panelDidClose — thrash loop
//   ❌ reload() before panelIsOpen = true — race with onChange
//   ❌ remove .frame(maxWidth: .infinity) from root views — fittingSize breaks
//
// ═══════════════════════════════════════════════════════════════════════════════

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private(set) var panel: PanelChrome?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // Guard: reload() only fires while panel is closed.
    private var panelIsOpen = false

    // Fixed canvas width. All views use .frame(maxWidth: .infinity) inside this.
    static let fixedWidth: CGFloat = 340

    // Maximum content height before panel would go off-screen.
    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.85
    }

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Build hosting controller once. rootView is always reset to mainView()
        // after close so openPanel() always measures the correct height.
        let hc = NSHostingController(rootView: mainView())
        hc.view.frame = NSRect(origin: .zero,
                               size: NSSize(width: Self.fixedWidth, height: 300))
        self.hc = hc

        // Build panel and embed hosting view.
        let panel = PanelChrome()
        panel.onClose = { [weak self] in self?.panelDidClose() }
        panel.hostingView = hc.view
        self.panel = panel

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image =
                makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // Guard: never trigger SwiftUI re-render while panel is visible.
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: — Panel lifecycle

    func panelDidClose() {
        panelIsOpen = false
        // Reset to level 1 so next open measures mainView fittingSize.
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
    //
    // NSPanel: navigate() CAN call updateHeight() because we own the position.
    // Two async hops ensure SwiftUI finishes layout before we read fittingSize.
    private func navigate(to view: AnyView) {
        hc?.rootView = view
        remeasureAsync()
    }

    // MARK: — Panel show/hide

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard let button = statusItem?.button,
              button.window != nil,
              let panel, let hc else { return }

        // Step 1: guard must be live before reload() fires.
        panelIsOpen = true
        // Step 2: feed fresh data so fittingSize is current.
        observable.reload()

        // Step 3: measure height after one run-loop tick (SwiftUI needs it).
        DispatchQueue.main.async {
            let h = min(hc.view.fittingSize.height, self.maxContentHeight)
            let contentH = h > 0 ? h : 300
            panel.positionBelow(button: button, contentHeight: contentH)
        }
    }

    // Two async hops: hop1 commits new rootView, hop2 reads stable fittingSize.
    private func remeasureAsync() {
        guard let panel, let hc else { return }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let h = min(hc.view.fittingSize.height, self.maxContentHeight)
                if h > 0 { panel.updateHeight(h) }
            }
        }
    }
}
