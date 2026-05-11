import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
//
// ARCHITECTURE IN USE: Architecture 1 — Fully Dynamic Height (SwiftUI-driven)
// (per status-bar-app-position-warning.md §4 Architecture 1)
//
// CONTRACT (DO NOT VIOLATE ANY RULE):
//
//   sizingOptions = .preferredContentSize
//     NSHostingController publishes preferredContentSize from SwiftUI ideal size.
//     NSPopover reads this automatically. Height is dynamic. Width is always
//     idealWidth (420) declared on the root VStack in PopoverMainView — never changes.
//
//   ❌ NEVER set popover.contentSize anywhere — not in openPopover, navigate, or anywhere else.
//   ❌ NEVER set hc.view.setFrameSize — let SwiftUI drive sizing entirely.
//   ❌ NEVER set sizingOptions = [] — that reverts to fixed size, empty space returns.
//   ❌ NEVER use .frame(width: 420) on any root view — must be .frame(idealWidth: 420).
//   ❌ NEVER add KVO/observers that write back to contentSize.
//   ❌ NEVER call performClose() + show() for navigation — causes full re-anchor.
//   ❌ NEVER touch sizing in onChange or any polling callback.
//   ❌ NEVER wrap ActionsListView in ScrollView — kills natural content height reporting.
//   ❌ NEVER read fittingSize.width — unstable.
//   ❌ NEVER call layoutSubtreeIfNeeded().
//
//   navigate() = rootView swap ONLY. Zero sizing calls. Ever.
//
// WHY idealWidth WORKS:
//   .frame(idealWidth: 420) on the root VStack of PopoverMainView pins
//   preferredContentSize.width to exactly 420 regardless of nav state.
//   Width never changes → no re-anchor → no side jump.
//   Height varies freely with content → no empty space.
//
// WHY systemStats MUST BE STOPPED WHILE POPOVER IS OPEN (ref #375 #376 #377 — THE KEY FIX):
//   SystemStatsViewModel fires @Published updates every ~1s.
//   Each update → SwiftUI layout pass → new preferredContentSize.height
//   → NSPopover re-anchors the window → visible position jump.
//   FIX: AppDelegate passes `isPopoverOpen: popoverIsOpen` to PopoverMainView.
//        PopoverMainView's .onChange(of: isPopoverOpen) stops systemStats when
//        the popover opens and restarts it when the popover closes.
// ❌ NEVER remove the isPopoverOpen parameter from the PopoverMainView constructor call.
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
        // ⚠️ Architecture 1: sizingOptions = .preferredContentSize
        //   NSHostingController publishes SwiftUI ideal size as preferredContentSize.
        //   NSPopover reads it automatically — dynamic height, stable width.
        //   The root VStack in PopoverMainView uses .frame(idealWidth: 420) which
        //   pins preferredContentSize.width = 420 always. Height varies freely.
        // ❌ NEVER change to [] — reverts to fixed size → empty space or clipping.
        controller.sizingOptions = .preferredContentSize
        hostingController = controller
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        // ⚠️ Do NOT set pop.contentSize here or anywhere else (Architecture 1).
        //   NSPopover will read preferredContentSize from the hosting controller.
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ⚠️ Guard: prevents double-reload while popover is open.
            // ❌ NEVER touch contentSize or sizing here.
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
            // ⚠️ FIX: Pass current popover open state so PopoverMainView can gate
            // SystemStatsViewModel. Without this, systemStats fires @Published updates
            // every ~1s while the popover is shown → SwiftUI layout passes →
            // preferredContentSize changes → NSPopover re-anchors → position jump.
            // ❌ NEVER remove this parameter.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            isPopoverOpen: popoverIsOpen
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

    /// Swaps rootView ONLY. NO sizing calls, NO contentSize, NO setFrameSize.
    /// Architecture 1: SwiftUI drives height via preferredContentSize automatically.
    /// ❌ NEVER add setFrameSize or contentSize here.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
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

    /// Opens the popover.
    /// Architecture 1: NO contentSize set here. NSPopover reads preferredContentSize
    /// from the hosting controller automatically. Width is stable at 420 (idealWidth).
    /// Height is fully dynamic from SwiftUI content.
    /// ❌ NEVER set popover.contentSize here or anywhere else.
    /// ❌ NEVER call setFrameSize.
    @MainActor
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover
        else { return }
        popoverIsOpen = true
        // Rebuild mainView with isPopoverOpen = true so PopoverMainView receives
        // the correct state and .onChange(of: isPopoverOpen) fires to stop systemStats.
        // ⚠️ This must happen BEFORE show() so the view is staged with the correct
        // isPopoverOpen value before NSPopover reads preferredContentSize.
        hostingController?.rootView = mainView()
        observable.reload()
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
// swiftlint:enable type_body_length
