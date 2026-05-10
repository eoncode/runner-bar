import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  POPOVER SIZING — DO NOT TOUCH WITHOUT READING ALL OF THIS  ☠️          ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║                                                                              ║
// ║  THE ONLY LEGAL SIZING MODEL — one place, one time:                         ║
// ║    openPopover() calls fittingSize ONCE on the hosting view,                ║
// ║    sets hostingController.view.frame + popover.contentSize,                 ║
// ║    then calls popover.show(). That is the complete contract.                ║
// ║    After show() returns: NOTHING touches size. Ever. For any reason.        ║
// ║                                                                              ║
// ║  navigate() IS ONE LINE:  hostingController?.rootView = view                ║
// ║    That is the complete function. No sizing. No async. Nothing else.        ║
// ║                                                                              ║
// ║  WHAT BROKE BEFORE (issue #13 — side-jump regression, 2026-05-10):         ║
// ║    A remeasurePopover() function was added and wired to TWO places:         ║
// ║      (a) navigate() via DispatchQueue.main.async after every nav tap        ║
// ║      (b) StepLogView.onLogLoaded after async log fetch completed            ║
// ║    Both called setFrameSize + contentSize while popover.isShown == true.    ║
// ║    AppKit recomputes the screen anchor on every contentSize change while    ║
// ║    the popover is visible → popover jumped sideways on every tap/load.      ║
// ║    Fix: delete remeasurePopover(). Remove onLogLoaded. One-line navigate(). ║
// ║                                                                              ║
// ║  WHAT BROKE BEFORE (fixed-height regression, 2026-05-10):                  ║
// ║    The revert of remeasurePopover() left navigate() as a one-liner but     ║
// ║    did NOT restore openPopover() to read fittingSize at open time.          ║
// ║    Result: every view used the same initial height of 300pt.                ║
// ║    Fix: openPopover() MUST call fittingSize before popover.show().          ║
// ║                                                                              ║
// ║  ABSOLUTE RULES — each one was learned by breaking production:              ║
// ║    ❌ NEVER call setFrameSize while popover.isShown == true                 ║
// ║    ❌ NEVER set popover.contentSize while popover.isShown == true           ║
// ║    ❌ NEVER add DispatchQueue.main.async (or any async) inside navigate()   ║
// ║    ❌ NEVER add a remeasurePopover() function or any equivalent             ║
// ║    ❌ NEVER wire onLogLoaded or any post-load callback to a resize          ║
// ║    ❌ NEVER set sizingOptions = .preferredContentSize                       ║
// ║    ❌ NEVER add objectWillChange.send() in reload()                         ║
// ║    ❌ NEVER remove .frame(idealWidth: 420) from PopoverMainView             ║
// ║    ❌ NEVER change fixedWidth without also changing idealWidth in           ║
// ║       PopoverMainView (mismatch wraps text → wrong fittingSize height)      ║
// ║    ❌ NEVER call reload() from popoverDidClose()                            ║
// ║    ❌ NEVER add a second call to setFrameSize or contentSize anywhere       ║
// ║                                                                              ║
// ║  THE ONLY SAFE SITE FOR setFrameSize + contentSize IS openPopover().        ║
// ║  These two calls are safe there because the popover is NOT yet shown.       ║
// ║  Replicate them anywhere else and you will break sizing or cause jumping.   ║
// ║                                                                              ║
// ║  If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT        ║
// ║  ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║  is removed is major major major.                                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

/// Navigation state machine for the popover's view hierarchy.
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
    /// Settings view.
    case settings
}

// MARK: - AppDelegate

/// Application delegate. Owns the status-bar item, NSPopover, and navigation state.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?

    // ⚠️ MUST be set to true BEFORE reload() on open. NEVER remove.
    // Guards the onChange handler so it does not call reload() while the
    // popover is open (which would clobber the live view mid-navigation).
    // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    private var popoverIsOpen = false

    /// Fixed popover width — MUST match PopoverMainView's .frame(idealWidth: 420).
    /// ❌ NEVER change this value without also updating idealWidth in PopoverMainView.
    /// Mismatch causes fittingSize.height to be computed at the wrong width,
    /// wrapping text and producing an incorrect popover height.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    private static let fixedWidth: CGFloat = 420

    // MARK: - App lifecycle

    /// Bootstraps the status-bar item, hosting controller, and popover at launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }
        let controller = NSHostingController(rootView: mainView())
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        controller.view.frame = NSRect(origin: .zero, size: initialSize)
        hostingController = controller
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentSize = initialSize
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
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

    /// Resets navigation state after the popover closes.
    /// ❌ NEVER call reload() here — it mutates observable state on a just-closed
    /// popover and can clobber savedNavState before openPopover() reads it.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
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
        guard job.steps.isEmpty
                || job.steps.contains(where: { $0.status == "in_progress" }),
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
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    /// Navigation level 2a: flat job list for a commit/PR group.
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
    ///
    /// ☠️ onLogLoaded IS NOT PASSED HERE — DO NOT ADD IT.
    /// Passing onLogLoaded caused issue #13 (side-jump): the closure called
    /// setFrameSize + contentSize while popover.isShown == true, making AppKit
    /// recompute the screen anchor and jump the popover sideways on every log load.
    /// StepLogView's ScrollView absorbs log content of any length. No resize needed.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
            // ☠️ NO onLogLoaded — see docstring above. Do NOT add it.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
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

    /// Settings view.
    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            store: observable
        ))
    }

    /// Navigation level 3: log output for a step (Jobs path).
    ///
    /// ☠️ onLogLoaded IS NOT PASSED HERE — DO NOT ADD IT.
    /// See logViewFromAction() for the full explanation.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
            // ☠️ NO onLogLoaded — do NOT add it. See logViewFromAction() docstring.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
        ))
    }

    /// Returns a refreshed view for `state` using live RunnerStore data, or `nil` if stale.
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
        case .settings:
            return settingsView()
        }
    }

    // MARK: - Navigation

    // ╔══════════════════════════════════════════════════════════════════════╗
    // ║  ☠️  navigate() — THIS IS THE COMPLETE FUNCTION. ONE LINE. FOREVER. ║
    // ╠══════════════════════════════════════════════════════════════════════╣
    // ║  ❌ NEVER add DispatchQueue.main.async here                          ║
    // ║  ❌ NEVER add DispatchQueue.global here                              ║
    // ║  ❌ NEVER call setFrameSize here                                     ║
    // ║  ❌ NEVER set popover.contentSize here                               ║
    // ║  ❌ NEVER call remeasurePopover() or any equivalent here             ║
    // ║  ❌ NEVER add a guard + isShown check that leads to a resize         ║
    // ║                                                                      ║
    // ║  WHY: touching contentSize while popover.isShown == true causes      ║
    // ║  AppKit to recompute the screen anchor → popover jumps sideways.     ║
    // ║  This was issue #13. It was fixed by making this a one-liner.        ║
    // ║  Do not break it again.                                              ║
    // ║                                                                      ║
    // ║  If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ║
    // ║  ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this    ║
    // ║  comment is removed is major major major.                            ║
    // ╚══════════════════════════════════════════════════════════════════════╝
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

    // ╔══════════════════════════════════════════════════════════════════════════╗
    // ║  ☠️  openPopover() — THE ONE AND ONLY LEGAL SITE FOR SIZING  ☠️          ║
    // ╠══════════════════════════════════════════════════════════════════════════╣
    // ║  setFrameSize and contentSize are called here because the popover is    ║
    // ║  NOT yet shown when they fire. That is the only safe window.            ║
    // ║                                                                          ║
    // ║  ❌ NEVER replicate setFrameSize or contentSize anywhere else           ║
    // ║  ❌ NEVER call setFrameSize after popover.show() returns                ║
    // ║  ❌ NEVER set contentSize after popover.show() returns                  ║
    // ║  ❌ NEVER move this sizing logic into navigate() or any callback        ║
    // ║                                                                          ║
    // ║  fittingSize is read here so the popover height fits the CURRENT        ║
    // ║  rootView content (main = short, detail = taller, log = tallest).       ║
    // ║  Removing the fittingSize read causes all views to render at 300pt.     ║
    // ║                                                                          ║
    // ║  If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT    ║
    // ║  ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this        ║
    // ║  comment is removed is major major major.                               ║
    // ╚══════════════════════════════════════════════════════════════════════════╝
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }
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
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
