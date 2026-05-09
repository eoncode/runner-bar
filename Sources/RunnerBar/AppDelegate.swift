import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296)
//
// SIZING RULES:
//   • fittingSize must be read on the NEXT run-loop tick after rootView swap.
//     SwiftUI defers layout; reading it synchronously returns the PREVIOUS view’s size.
//   • Detail views contain ScrollView which reports 0 fittingSize.height. Use a
//     fixed detailHeight for them instead, capped so they don’t overflow the screen.
//   • Main view has no ScrollView — fittingSize is reliable on the next tick.
//   • Both hostCtrl.view.setFrameSize AND popover.contentSize MUST be updated together.
//     Updating only one leaves NSPopover chrome and NSView frame out of sync → clipping.
//
// WIDTH RULES (anti side-jump):
//   • Width is ALWAYS PopoverSize.width (420). Never derive from fittingSize.width.
//   • PopoverMainView uses .frame(idealWidth: 420). Detail views use maxWidth:.infinity.
//   • Changing width while popover is shown causes the popover to jump sideways.
//   ❌ NEVER use fittingSize.width for any navigate() call
//   ❌ NEVER pass a width other than PopoverSize.width to applySize()
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER touch contentSize or setFrameSize from outside navigate()
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 420) from PopoverMainView
// ❌ NEVER call layoutSubtreeIfNeeded() synchronously right after rootView swap

// MARK: - Constants
private enum PopoverSize {
    static let width: CGFloat = 420
    static let fallbackHeight: CGFloat = 300
    /// Fixed height for views with ScrollView that cannot use fittingSize.
    /// Used for JobDetailView, StepLogView, SettingsView.
    static let detailHeight: CGFloat = 480
    /// Maximum popover height on screen (leaves room for the menu bar).
    static let maxHeight: CGFloat = 620

    /// Content-fitted height for ActionDetailView.
    /// Header + title block is ~110 pt. Each job row is ~26 pt.
    /// Capped at detailHeight so very long lists don’t overflow the screen.
    static func actionDetailHeight(jobCount: Int) -> CGFloat {
        let headerPt: CGFloat = 110
        let rowPt: CGFloat = 26
        let raw = headerPt + CGFloat(max(1, jobCount)) * rowPt + 16 // 16 pt bottom pad
        return min(raw, detailHeight)
    }
}

private enum NavState {
    case main
    case jobDetail(ActiveJob)
    case stepLog(ActiveJob, JobStep)
    case actionDetail(ActionGroup)
    case actionJobDetail(ActiveJob, ActionGroup)
    case actionStepLog(ActiveJob, JobStep, ActionGroup)
    case settings

    /// Views that contain a ScrollView and cannot be measured via fittingSize.
    var usesFixedDetailHeight: Bool {
        switch self {
        case .main: return false
        default: return true
        }
    }
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
        let initialSize = NSSize(width: PopoverSize.width, height: PopoverSize.fallbackHeight)
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
                        self.navigate(to: self.detailView(job: enriched), fixedHeight: PopoverSize.detailHeight)
                    }
                }
            },
            onSelectAction: { [weak self] group in
                guard let self else { return }
                let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                let h = PopoverSize.actionDetailHeight(jobCount: latest.jobs.count)
                self.navigate(to: self.actionDetailView(group: latest), fixedHeight: h)
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView(), fixedHeight: PopoverSize.detailHeight)
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
                self.navigate(to: self.mainView(), fixedHeight: nil)
            },
            onSelectJob: { [weak self] job in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.popoverIsOpen else { return }
                        self.navigate(to: self.detailViewFromAction(job: enriched, group: group),
                                      fixedHeight: PopoverSize.detailHeight)
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
                let h = PopoverSize.actionDetailHeight(jobCount: group.jobs.count)
                self.navigate(to: self.actionDetailView(group: group), fixedHeight: h)
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                self.navigate(to: self.logViewFromAction(job: job, step: step, group: group),
                              fixedHeight: PopoverSize.detailHeight)
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
                let h = PopoverSize.actionDetailHeight(jobCount: group.jobs.count)
                self.navigate(to: self.detailViewFromAction(job: job, group: group), fixedHeight: h)
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
                self.navigate(to: self.mainView(), fixedHeight: nil)
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                self.navigate(to: self.logView(job: job, step: step), fixedHeight: PopoverSize.detailHeight)
            }
        ))
    }

    @MainActor
    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView(), fixedHeight: nil)
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
                self.navigate(to: self.detailView(job: job), fixedHeight: PopoverSize.detailHeight)
            }
        ))
    }

    @MainActor
    private func validatedView(for state: NavState) -> (AnyView, CGFloat?)? {
        savedNavState = nil
        let store = RunnerStore.shared
        switch state {
        case .main:
            return nil
        case .jobDetail(let job):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return (detailView(job: live), PopoverSize.detailHeight)
        case .stepLog(let job, let step):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return (logView(job: live, step: step), PopoverSize.detailHeight)
        case .actionDetail(let group):
            guard let live = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return (actionDetailView(group: live), PopoverSize.actionDetailHeight(jobCount: live.jobs.count))
        case .actionJobDetail(let job, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return (detailViewFromAction(job: liveJob, group: liveGroup), PopoverSize.detailHeight)
        case .actionStepLog(let job, let step, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return (logViewFromAction(job: liveJob, step: step, group: liveGroup), PopoverSize.detailHeight)
        case .settings:
            return (settingsView(), PopoverSize.detailHeight)
        }
    }

    // MARK: - Navigation

    /// Swap the root view and resize the popover to fit.
    ///
    /// - Parameters:
    ///   - view:        The new root view.
    ///   - fixedHeight: When non-nil, use this exact height (for views with ScrollView
    ///                  whose fittingSize.height is 0). When nil, defer one run-loop tick
    ///                  then measure fittingSize — correct for the main view (no ScrollView).
    ///
    /// ⚠️ Width is ALWAYS PopoverSize.width. Never varies. Changing width while shown = side-jump.
    /// ⚠️ Both hostCtrl.view.setFrameSize AND popover.contentSize MUST be set; one alone causes clipping.
    @MainActor
    private func navigate(to view: AnyView, fixedHeight: CGFloat?) {
        guard let hostCtrl = hostingController, let pop = popover else {
            hostingController?.rootView = view
            return
        }
        hostCtrl.rootView = view
        guard popoverIsOpen else { return }

        if let h = fixedHeight {
            applySize(NSSize(width: PopoverSize.width, height: min(h, PopoverSize.maxHeight)),
                      hc: hostCtrl, pop: pop)
        } else {
            DispatchQueue.main.async { [weak self, weak hostCtrl, weak pop] in
                guard let self, let hostCtrl, let pop, self.popoverIsOpen else { return }
                hostCtrl.view.layoutSubtreeIfNeeded()
                let fit = hostCtrl.view.fittingSize
                let h = fit.height > 0 ? fit.height : PopoverSize.fallbackHeight
                self.applySize(NSSize(width: PopoverSize.width, height: min(h, PopoverSize.maxHeight)),
                               hc: hostCtrl, pop: pop)
            }
        }
    }

    @MainActor
    private func applySize(_ size: NSSize, hc: NSHostingController<AnyView>, pop: NSPopover) {
        hc.view.setFrameSize(size)
        pop.contentSize = size
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

    @MainActor
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }
        popoverIsOpen = true
        observable.reload()
        let tempSize = NSSize(width: PopoverSize.width, height: PopoverSize.fallbackHeight)
        hostingController.view.setFrameSize(tempSize)
        popover.contentSize = tempSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        if let saved = savedNavState, let (restored, h) = validatedView(for: saved) {
            navigate(to: restored, fixedHeight: h)
            return
        }
        DispatchQueue.main.async { [weak self, weak hostingController, weak popover] in
            guard let self, let hostCtrl = hostingController, let pop = popover,
                  self.popoverIsOpen else { return }
            hostCtrl.view.layoutSubtreeIfNeeded()
            let fit = hostCtrl.view.fittingSize
            let h = fit.height > 0 ? fit.height : PopoverSize.fallbackHeight
            self.applySize(NSSize(width: PopoverSize.width,
                                  height: min(h, PopoverSize.maxHeight)),
                           hc: hostCtrl, pop: pop)
        }
    }
}
// swiftlint:enable type_body_length
