import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296)
//
// SIZING CONTRACT:
//   openPopover() sets size once from PopoverMainView fittingSize (deferred one tick).
//   navigate() resizes the popover to the incoming view's fittingSize so detail
//   views shrink/grow to fit their content rather than inheriting main-view height.
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER call setFrameSize while popover.isShown == true from outside navigate()
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 420) from PopoverMainView
// ❌ NEVER remove the !popoverIsOpen guard on reload() in onChange
// ❌ NEVER move the fittingSize read back to the same tick as reload()

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

    private static let fixedWidth: CGFloat = 420
    private static let maxHeight: CGFloat = 620
    private static let minHeight: CGFloat = 120

    // MARK: - App lifecycle

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
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            if !self.popoverIsOpen { self.observable.reload() }
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

    private func enrichGroupIfNeeded(_ group: ActionGroup) -> ActionGroup {
        guard group.jobs.isEmpty else { return group }
        let fetched = fetchActionGroups(for: group.repo)
        return fetched.first(where: { $0.id == group.id }) ?? group
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
                DispatchQueue.global(qos: .userInitiated).async {
                    let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                    let enriched = self.enrichGroupIfNeeded(latest)
                    DispatchQueue.main.async {
                        guard self.popoverIsOpen else { return }
                        self.navigate(to: self.actionDetailView(group: enriched))
                    }
                }
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
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

    /// Swaps rootView and resizes popover to fit the new view's content.
    /// This allows detail views to be shorter than the main view.
    private func navigate(to view: AnyView) {
        guard let hc = hostingController, let pop = popover else { return }
        hc.rootView = view
        // Defer one tick so SwiftUI lays out the new rootView before we measure.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popoverIsOpen else { return }
            let fitting = hc.view.fittingSize
            let width = fitting.width > 0 ? fitting.width : Self.fixedWidth
            let height = min(max(fitting.height > 0 ? fitting.height : 300, Self.minHeight), Self.maxHeight)
            let size = NSSize(width: width, height: height)
            hc.view.setFrameSize(size)
            pop.contentSize = size
        }
    }

    // MARK: - Popover show/hide

    @MainActor @objc private func togglePopover() {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover. Size is set once from PopoverMainView fittingSize,
    /// deferred one async tick so SwiftUI layout from reload() is current.
    /// ❌ NEVER move fittingSize read back to same tick as reload().
    @MainActor
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil
        else { return }
        popoverIsOpen = true
        observable.reload()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let hc = self.hostingController,
                  let pop = self.popover,
                  let btn = self.statusItem?.button,
                  btn.window != nil
            else { return }
            let fitting = hc.view.fittingSize
            let width = fitting.width > 0 ? fitting.width : Self.fixedWidth
            let height = min(fitting.height > 0 ? fitting.height : 300, Self.maxHeight)
            let size = NSSize(width: width, height: height)
            hc.view.setFrameSize(size)
            pop.contentSize = size
            pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .maxY)
            pop.contentViewController?.view.window?.makeKey()
            if let saved = self.savedNavState,
               let restored = self.validatedView(for: saved) {
                self.navigate(to: restored)
            }
        }
    }
}
// swiftlint:enable type_body_length
