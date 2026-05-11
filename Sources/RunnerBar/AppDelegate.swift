import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
//
// ARCHITECTURE IN USE: Architecture 2 — Fixed Size (AppDelegate-owned)
// (per status-bar-app-position-warning.md §4 Architecture 2)
//
// CONTRACT (DO NOT VIOLATE ANY RULE):
//
//   sizingOptions = []
//     NSHostingController does NOT auto-propagate preferredContentSize.
//     AppDelegate owns contentSize exclusively.
//     contentSize is set before show() and on every navigate() call.
//     It is NEVER set from a timer, store update, or any polling callback.
//
//   ✅ Set contentSize = fittingSize in openPopover() before show().
//   ✅ Set contentSize = fittingSize in navigate() after rootView swap.
//   ❌ NEVER set contentSize from a timer, onChange, store update, or polling.
//   ❌ NEVER set hc.view.setFrameSize anywhere.
//   ❌ NEVER use sizingOptions = .preferredContentSize — re-introduces the jump.
//   ❌ NEVER call performClose() + show() for navigation — causes full re-anchor.
//
// WHY THIS WORKS (no jump on navigate):
//   contentSize is updated synchronously in navigate() via layoutSubtreeIfNeeded()+fittingSize.
//   NSPopover resizes its window in-place (no re-anchor) when contentSize changes
//   while already shown — it only re-anchors on show().
//   Timer ticks and store updates never touch contentSize → no spurious re-anchor.
//
// WHY systemStats IS STOPPED WHILE POPOVER IS OPEN (ref #375 #376 #377 — CPU GUARD):
//   systemStats fires @Published every ~1s. With sizingOptions=[] it cannot cause jumps.
//   It is still stopped while the popover is open to save CPU.
// ❌ NEVER remove the isPopoverOpen parameter from PopoverMainView — it stops systemStats.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

private enum NavState {
    case main
    case jobDetail(ActiveJob)
    case stepLog(ActiveJob, JobStep)
    case actionDetail(ActionGroup)
    case actionJobDetail(ActiveJob, ActionGroup)
    case actionStepLog(ActiveJob, JobStep, ActionGroup)
    case settings
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    @MainActor private lazy var observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var popoverIsOpen = false

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }
        let controller = NSHostingController(rootView: mainView())
        // ⚠️ Architecture 2: sizingOptions = []
        //   AppDelegate owns contentSize. Set in openPopover() and navigate().
        // ❌ NEVER change to .preferredContentSize — re-introduces the side jump.
        controller.sizingOptions = []
        hostingController = controller
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            if !self.popoverIsOpen {
                DispatchQueue.main.async { self.observable.reload() }
            }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - View factories

    private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty
                || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        return makeActiveJob(from: fresh, iso: ISO8601DateFormatter(), isDimmed: job.isDimmed)
    }

    @MainActor
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
            },
            isPopoverOpen: popoverIsOpen
        ))
    }

    // ⚠️ openPopoverView() — identical to mainView() but always passes isPopoverOpen: true.
    // Used ONLY inside openPopover() so systemStats is stopped on first render (CPU guard).
    // ❌ NEVER use mainView() inside openPopover().
    // ❌ NEVER use this method anywhere except openPopover().
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @MainActor
    private func openPopoverView() -> AnyView {
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
            },
            // ⚠️ CRITICAL: literal true — CPU guard, stops systemStats on first render.
            // ❌ NEVER change to popoverIsOpen here.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            isPopoverOpen: true
        ))
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    /// Swaps rootView and updates contentSize to match the new view's fittingSize.
    /// NSPopover resizes in-place (no re-anchor) when contentSize changes while shown.
    /// contentSize is ONLY ever set here and in openPopover() — never from timers or store updates.
    /// ❌ NEVER call this from a timer, onChange, or any polling path.
    private func navigate(to view: AnyView) {
        guard let hc = hostingController, let popover else { return }
        hc.rootView = view
        // ⚠️ Update contentSize after rootView swap so the popover resizes to the new view.
        // layoutSubtreeIfNeeded() forces AppKit to compute the new fittingSize synchronously.
        // NSPopover.contentSize setter while shown = in-place resize, NOT a re-anchor.
        // ❌ NEVER call this from anywhere except navigate() and openPopover().
        hc.view.layoutSubtreeIfNeeded()
        let fitting = hc.view.fittingSize
        let newHeight = fitting.height > 0 ? fitting.height : 480
        popover.contentSize = NSSize(width: 420, height: newHeight)
    }

    // MARK: - Popover show/hide

    @MainActor @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover. Sets contentSize once from fittingSize before show().
    /// ❌ NEVER set popover.contentSize after show() except via navigate().
    /// ❌ NEVER replace openPopoverView() with mainView() here.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    @MainActor
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc = hostingController
        else { return }
        popoverIsOpen = true
        // ⚠️ Use openPopoverView() — passes isPopoverOpen: true (literal) for CPU guard.
        // ❌ NEVER change to mainView() here.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        hc.rootView = openPopoverView()
        observable.reload()
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            hc.rootView = restored
        }
        hc.view.layoutSubtreeIfNeeded()
        let fitting = hc.view.fittingSize
        let popoverHeight = fitting.height > 0 ? fitting.height : 480
        popover.contentSize = NSSize(width: 420, height: popoverHeight)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
// swiftlint:enable type_body_length
