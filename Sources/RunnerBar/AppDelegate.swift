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
//   Height is read via hostingController.view.fittingSize.height ONCE per open in openPopover().
//   fittingSize reads SwiftUI ideal size ONE TIME while popover is CLOSED.
//   sizingOptions=.preferredContentSize would re-read it CONTINUOUSLY → re-anchor → jump.
//   So we rely on the default (which is []) and read fittingSize manually.
//   popover.contentSize set manually ONLY in two safe places:
//     1. applicationDidFinishLaunching (popover not yet shown)
//     2. openPopover() (popover is CLOSED, isShown==false guaranteed)
//   navigate() swaps hostingController.rootView ONLY. Zero size changes. Ever.
//
// ── NAVIGATION LEVELS ───────────────────────────────────────────────────────────
//   Jobs path (Active Jobs section):
//     Level 1: PopoverMainView   — runner status + jobs + actions
//     Level 2: JobDetailView     — step list for a selected job
//     Level 3: StepLogView       — log output for a selected step
//
//   Actions path (Actions section):
//     Level 1:  PopoverMainView    — same root
//     Level 2a: ActionDetailView   — jobs inside a commit/PR group
//     Level 3a: JobDetailView      — steps (existing, reused)
//     Level 4a: StepLogView        — log (existing, reused)
//
//   All levels navigate via navigate() — rootView swap only, ZERO size changes.
//   All levels use ScrollView for content that may overflow the fixed frame.
//   The fixed frame is sized ONCE in openPopover() from mainView()'s fittingSize.
//   Because the frame never changes after open, all levels must fit within it
//   using their own ScrollView — that is the correct contract, not fighting the frame.
//
//   Back-navigation chain:
//     StepLogView.onBack       → detailView(job:) OR logViewFromAction
//     JobDetailView.onBack     → mainView() OR actionDetailView(group:)
//     ActionDetailView.onBack  → mainView()
//     popoverDidClose          → reset hostingController.rootView = mainView() (async)
//
// ── WHY NOT preferredContentSize ─────────────────────────────────────────────
//   preferredContentSize causes NSPopover to re-anchor on every hostingController.rootView swap.
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
//     ✔ hostingController.rootView = newView  (SwiftUI updates in-place, no re-anchor)
//     ✖ contentSize  ← LEFT-JUMP
//     ✖ setFrameSize ← LEFT-JUMP
//
//   openPopover() (isShown == false, guaranteed):
//     ✔ setFrameSize  (popover is CLOSED)
//     ✔ contentSize   (popover is CLOSED)
//     ✔ fittingSize read (reads SwiftUI ideal size once, safely)
//     ✖ hostingController.rootView   ← new SwiftUI tree → deferred layout fires AFTER show() → LEFT-JUMP
//
//   popoverDidClose:
//     ✔ popoverIsOpen = false
//     ✔ hostingController.rootView = mainView() via async dispatch (popover already closed, safe)
//     ✖ reload() ← objectWillChange → .transient treats as outside-click → thrash loop
//     ✖ contentSize ← avoid even during close — timing is ambiguous
//
// ── ABSOLUTE NEVER LIST ─────────────────────────────────────────────────────
//   ❌ sizingOptions = .preferredContentSize → re-anchors on every rootView swap
//   ❌ contentSize while isShown==true → left-jump
//   ❌ setFrameSize while isShown==true → left-jump
//   ❌ hostingController.rootView in openPopover() → deferred layout → left-jump
//   ❌ reload() from popoverDidClose → thrash loop
//   ❌ reload() before popoverIsOpen=true → race: re-render fires after show() → jump
//   ❌ objectWillChange.send() in reload() → double re-render
//   ❌ remove .frame(idealWidth: 340) from PopoverMainView → fittingSize returns 0 width
//   ❌ add size changes in navigate() → popover is open → left-jump
//   ❌ add size changes in onChange → popover may be open → left-jump
//
// ═══════════════════════════════════════════════════════════════════════════════

private enum NavState {
    case main
    case jobDetail(ActiveJob)
    case stepLog(ActiveJob, JobStep)
    case actionDetail(ActionGroup)
    case actionJobDetail(ActiveJob, ActionGroup)
    case actionStepLog(ActiveJob, JobStep, ActionGroup)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?

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
        let hostingController = NSHostingController(rootView: mainView())
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
        self.hostingController = hostingController

        let popover = NSPopover()
        popover.behavior              = .transient   // closes on outside click
        popover.animates              = false         // avoids animation triggering size reads
        popover.contentSize           = initialSize
        popover.contentViewController = hostingController
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
    // hostingController.rootView is always mainView() so openPopover() reads the correct
    // fittingSize (mainView height, not detailView or logView height).
    // The reset is async so it fires after the popover close animation completes.
    // It is safe because the popover is already closed — no re-anchor is possible.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false  // ❌ NEVER add reload() or contentSize here
        // Reset to level 1 so next open always measures mainView fittingSize.
        // Async dispatch: popover close animation may still be running synchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: — View factories

    private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    // mainView() — navigation level 1.
    // onSelectJob → level 2 (detailView); onSelectAction → level 2a (actionDetailView).
    private func mainView() -> AnyView {
        savedNavState = nil
        return AnyView(PopoverMainView(
            store: observable,
            onSelectJob: { [weak self] job in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.popoverIsOpen else { return }
                        self.navigate(to: self.detailView(job: enriched))
                    }
                }
            },
            onSelectAction: { [weak self] group in
                guard let self else { return }
                let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                self.navigate(to: self.actionDetailView(group: latest))
            }
        ))
    }

    // actionDetailView(group:) — navigation level 2a (Actions path).
    // Shows the flat job list for a commit/PR group.
    // onBack → level 1; onSelectJob → level 3a.
    private func actionDetailView(group: ActionGroup) -> AnyView {
        savedNavState = .actionDetail(group)
        return AnyView(ActionDetailView(
            group: group,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onSelectJob: { [weak self] job in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.popoverIsOpen else { return }
                        self.navigate(to: self.detailViewFromAction(job: enriched, group: group))
                    }
                }
            }
        ))
    }

    // detailViewFromAction(job:group:) — navigation level 3a.
    // Reuses JobDetailView; onBack returns to actionDetailView, not mainView.
    private func detailViewFromAction(job: ActiveJob, group: ActionGroup) -> AnyView {
        savedNavState = .actionJobDetail(job, group)
        return AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.actionDetailView(group: group))
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                self.navigate(to: self.logViewFromAction(job: job, step: step, group: group))
            }
        ))
    }

    // logViewFromAction — navigation level 4a. onBack → level 3a.
    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
        ))
    }

    // detailView(job:) — navigation level 2.
    // onBack navigates back to level 1 (mainView).
    // onSelectStep navigates forward to level 3 (logView).
    //
    // The callbacks use [weak self] to avoid retain cycles. AppDelegate owns the
    // popover and hostingController; if AppDelegate were deallocated, the closure guard would
    // prevent a crash. In practice AppDelegate lives for the app's lifetime.
    private func detailView(job: ActiveJob) -> AnyView {
        savedNavState = .jobDetail(job)
        return AnyView(JobDetailView(
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
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
        ))
    }

    // Returns a refreshed view for the saved nav state using live RunnerStore data,
    // or nil if the entity is gone (or state is .main — caller stays on mainView).
    private func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil  // prevent factory side-effects from seeding next cycle
        let store = RunnerStore.shared
        switch state {
        case .main:
            return nil

        case .jobDetail(let job):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return detailView(job: live)

        case .stepLog(let job, let step):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return logView(job: live, step: step)

        case .actionDetail(let group):
            guard let live = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return actionDetailView(group: live)

        case .actionJobDetail(let job, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return detailViewFromAction(job: liveJob, group: liveGroup)

        case .actionStepLog(let job, let step, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return logViewFromAction(job: liveJob, step: step, group: liveGroup)
        }
    }

    // MARK: — Navigation

    // ⚠️ REGRESSION GUARD: rootView swap ONLY. ZERO size changes. FOREVER.
    //
    // navigate() fires while the popover IS open (user tapped a row inside it).
    // NSPopover.behavior = .transient closes only on clicks OUTSIDE the popover,
    // so any tap on a row inside leaves the popover visible and isShown==true.
    //
    // Swapping rootView triggers SwiftUI's in-place update mechanism:
    // SwiftUI diffs the new view tree against the old one and redraws in-place.
    // This does NOT cause NSPopover to re-anchor, because:
    //   a) contentSize is not touched (no left-jump trigger)
    //   b) sizingOptions is not .preferredContentSize (no continuous size tracking)
    //
    // The new view (detail/log) may be taller than the frame. That is expected.
    // ScrollView inside each view handles overflow — content scrolls within the
    // fixed frame. That is the correct contract. Fighting the frame = regressions.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
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
    // ⚠️ DO NOT reassign hostingController.rootView here.
    //   Reassigning rootView discards the SwiftUI tree and builds a new one.
    //   SwiftUI defers layout to the next run-loop tick → fires AFTER show() → left-jump.
    //   hostingController.rootView is always mainView() here because:
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
              let hostingController else { return }

        popoverIsOpen = true                      // ❌ Step 1: NEVER move below reload()
        observable.reload()                        // ❌ Step 2: NEVER move above popoverIsOpen = true

        let size = NSSize(
            width:  hostingController.view.fittingSize.width > 0
                        ? hostingController.view.fittingSize.width
                        : Self.fixedWidth,
            height: hostingController.view.fittingSize.height  // Step 3: read AFTER reload()
        )

        hostingController.view.setFrameSize(size)  // Step 4a: safe — isShown==false
        popover.contentSize = size                 // Step 4b: safe — isShown==false

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)  // Step 5
        popover.contentViewController?.view.window?.makeKey()
        // ⚠️ NOTHING that touches size after show(). isShown==true from here.
        // Restoring saved nav state is a rootView swap only (navigate()) — safe.
        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
