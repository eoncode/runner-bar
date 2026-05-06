import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  REGRESSION GUARD — READ THIS ENTIRE COMMENT BEFORE CHANGING ANYTHING
// ═══════════════════════════════════════════════════════════════════════════════
//
// This was broken and rewritten 30+ times. READ BEFORE TOUCHING.
// See issues #52, #54, #57, #59.
//
// ── ARCHITECTURE ───────────────────────────────────────────────────────────────
//   sizingOptions: default (NOT .preferredContentSize, NOT [])
//   Height read via hostingController.view.fittingSize.height ONCE per open.
//   fittingSize reads SwiftUI ideal size ONE TIME while popover is CLOSED.
//   popover.contentSize set manually ONLY in two safe places:
//     1. applicationDidFinishLaunching (popover not yet shown)
//     2. openPopover() (popover is CLOSED, isShown==false guaranteed)
//   navigate() swaps hostingController.rootView ONLY. Zero size changes. Ever.
//
// ── NAVIGATION LEVELS ─────────────────────────────────────────────────────
//   Jobs:    L1 PopoverMainView → L2 JobDetailView → L3 StepLogView
//   Actions: L1 PopoverMainView → L2a ActionDetailView → L3a JobDetailView → L4a StepLogView
//   All levels navigate via navigate() — rootView swap only, ZERO size changes.
//
// ── WHY NOT preferredContentSize ────────────────────────────────────────────
//   Causes NSPopover to re-anchor on every rootView swap → left-jump.
//   ❌ NEVER set sizingOptions = .preferredContentSize
//
// ── THE LEFT-JUMP RULE (#52 #54) ──────────────────────────────────────────────
//   contentSize and setFrameSize are FORBIDDEN while popover.isShown == true.
//
// ── ABSOLUTE NEVER LIST ─────────────────────────────────────────────────────
//   ❌ sizingOptions = .preferredContentSize
//   ❌ contentSize while isShown==true
//   ❌ setFrameSize while isShown==true
//   ❌ hostingController.rootView in openPopover()
//   ❌ reload() from popoverDidClose
//   ❌ reload() before popoverIsOpen=true
//   ❌ objectWillChange.send() in reload()
//   ❌ remove .frame(idealWidth: 340) from PopoverMainView
//   ❌ size changes in navigate()
//   ❌ size changes in onChange
//
// ═══════════════════════════════════════════════════════════════════════════════

/// Navigation state machine for the popover’s view hierarchy.
private enum NavState {
    /// Root level: PopoverMainView.
    case main
    /// Jobs path level 2: step list for a job.
    case jobDetail(ActiveJob)
    /// Jobs path level 3: log output for a step.
    case stepLog(ActiveJob, JobStep)
    /// Actions path level 2a: job list for a commit/PR group.
    case actionDetail(ActionGroup)
    /// Actions path level 3a: step list for a job reached via an action group.
    case actionJobDetail(ActiveJob, ActionGroup)
    /// Actions path level 4a: log output for a step reached via an action group.
    case actionStepLog(ActiveJob, JobStep, ActionGroup)
}

/// Application delegate. Owns the status-bar item, NSPopover, and navigation state.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?

    // ⚠️ CAUSE 2+4 guard. MUST be set to true BEFORE reload() on open.
    // ❌ NEVER remove this flag.
    private var popoverIsOpen = false

    /// Fixed popover width. PopoverMainView uses .frame(idealWidth: 340) to match.
    /// ❌ NEVER make width dynamic — anchor drift = left-jump.
    private static let fixedWidth: CGFloat = 340

    // MARK: - App lifecycle

    /// Bootstraps the status-bar item, hosting controller, and popover at launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hostingController = NSHostingController(rootView: mainView())
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
        self.hostingController = hostingController

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = initialSize
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(
                for: RunnerStore.shared.aggregateStatus
            )
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    /// Resets navigation state and queues a rootView reset after the popover closes.
    /// ❌ NEVER call reload() here — causes open/close thrash loop via .transient.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - View factories

    /// Re-fetches step data for `job` if steps are missing or stale.
    private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    /// Navigation level 1: runner status + jobs + actions.
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

    /// Navigation level 2a (Actions path): flat job list for a commit/PR group.
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

    /// Navigation level 3a: JobDetailView reached via an ActionGroup.
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

    /// Navigation level 4a: StepLogView reached via an ActionGroup.
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

    /// Navigation level 2: step list for a job (Jobs path).
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

    /// Navigation level 3: log output for a step (Jobs path).
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

    /// Returns a refreshed view for `state` using live RunnerStore data,
    /// or `nil` if the entity is no longer present.
    private func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil
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

    // MARK: - Navigation

    /// Swaps the hosting controller’s root view. ZERO size changes. Forever.
    ///
    /// ⚠️ REGRESSION GUARD: rootView swap ONLY. No contentSize, no setFrameSize.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - Popover show/hide

    /// Toggles the popover open or closed.
    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover. The ONE safe site for sizing.
    ///
    /// Order is non-negotiable:
    /// 1. popoverIsOpen = true (must precede reload)
    /// 2. observable.reload() (feeds fresh data before fittingSize read)
    /// 3. read fittingSize (must follow reload)
    /// 4. setFrameSize + contentSize (safe — isShown==false)
    /// 5. show() (must be last)
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController else { return }

        popoverIsOpen = true
        observable.reload()

        let fittingWidth = hostingController.view.fittingSize.width
        let size = NSSize(
            width: fittingWidth > 0 ? fittingWidth : Self.fixedWidth,
            height: hostingController.view.fittingSize.height
        )

        hostingController.view.setFrameSize(size)
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
