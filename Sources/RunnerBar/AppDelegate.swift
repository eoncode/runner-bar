import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
// See also: status-bar-app-position-warning.md — the project's canonical architecture guide.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE IN USE: Architecture 1 — Fully Dynamic Height (SwiftUI-driven)
// See status-bar-app-position-warning.md §4 for full spec.
//
// THE CORRECT ARCHITECTURE (zero-jump, true dynamic height):
//
//   sizingOptions = .preferredContentSize  ← REQUIRED for dynamic height.
//   NSHostingController reads SwiftUI’s idealSize (set via .frame(idealWidth:480))
//   and publishes it as preferredContentSize. NSPopover auto-tracks this.
//   preferredContentSize.width = always 480 (all views declare idealWidth:480).
//   preferredContentSize.height = varies freely with content = dynamic height.
//   Width is stable = no re-anchor = no side-jump.
//   ❌ NEVER change to sizingOptions = [] — breaks dynamic height entirely,
//      popover stays at initial size forever.
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//
//   openPopover() = calls show() only. ZERO contentSize. ZERO setFrameSize.
//   NSHostingController.preferredContentSize auto-propagates to the popover.
//
//   WHY WIDTH NEVER JUMPS:
//   contentSize.width = stable at 480 because ALL views declare .frame(idealWidth:480).
//   .frame(idealWidth:480) tells SwiftUI its ideal/preferred width = 480.
//   NSHostingController reads this as preferredContentSize.width = 480.
//   If ANY view uses a different idealWidth, or omits it, navigating there changes
//   preferredContentSize.width → NSPopover re-anchors → side-jump.
//   ❌ NEVER use .frame(width:480) — layout constraint ≠ ideal size.
//   ❌ NEVER omit .frame(idealWidth:480) from ANY view in the nav tree.
//   ❌ NEVER use a different idealWidth value in ANY view.
//
//   WHY HEIGHT IS DYNAMIC WITHOUT JUMPING:
//   PopoverMainView uses .fixedSize(horizontal:false, vertical:true) on the action
//   list (NOT ScrollView), capped via .frame(maxHeight: cap, alignment:.top).
//   fixedSize lets the list report its natural content height to SwiftUI.
//   That height flows to preferredContentSize.height → NSPopover auto-sizes.
//   HEIGHT CHANGES WHILE SHOWN ARE SAFE because NSPopover only re-anchors on
//   contentSize.WIDTH changes. Height changes are side-jump-free.
//   This is Architecture 1 from status-bar-app-position-warning.md.
//
//   WHY NO DATA POLL GUARD IS NEEDED (Architecture 1 difference from Arch 2):
//   In Architecture 1, store.reload() triggering a SwiftUI layout pass is SAFE.
//   The layout pass updates preferredContentSize.height (content-driven dynamic height).
//   That is exactly what we want. Width stays at 480. No jump.
//   The only thing to avoid is mutating @State that causes HEIGHT changes while shown
//   AND where those height changes are unwanted (e.g. InlineJobRowsView cap expansion).
//
//   OPEN SEQUENCE (correct order, do NOT reorder):
//   1. popoverIsOpen = true
//   2. observable.reload()       ← loads live data
//   3. show()                    ← NSHostingController renders with live data
//                                   preferredContentSize propagates automatically
//   4. navigate(to: restored)    ← rootView swap AFTER show. Zero sizing. Safe.
//
// ❌ NEVER set sizingOptions = [] — breaks height
// ❌ NEVER manually set contentSize anywhere (not even in applicationDidFinishLaunching)
// ❌ NEVER call setFrameSize in openPopover()
// ❌ NEVER use fittingSize anywhere
// ❌ NEVER use CATransaction.flush() anywhere (not needed with Architecture 1)
// ❌ NEVER add contentSize or setFrameSize to navigate()
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from ANY view in the nav tree
// ❌ NEVER use a different idealWidth value in ANY view (must all be 480)
// ❌ NEVER use .frame(width: 480) instead of .frame(idealWidth: 480)
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView has maxHeight:.infinity — may collapse popover if restored
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded
//    Called from DispatchQueue.global — pure network I/O, no @MainActor state
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var popoverIsOpen = false

    /// Canonical popover width. Must match idealWidth in ALL views in the nav tree.
    /// ❌ NEVER change without updating idealWidth in PopoverMainView, SettingsView,
    ///    JobDetailView, ActionDetailView, AND StepLogView.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let idealWidth: CGFloat = 480

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }
        let controller = NSHostingController(rootView: mainView())
        // ✅ sizingOptions = .preferredContentSize — ARCHITECTURE 1 REQUIREMENT.
        // This lets NSHostingController publish SwiftUI's idealSize as preferredContentSize.
        // NSPopover auto-tracks preferredContentSize → true dynamic height with no manual writes.
        // Width is always 480 (all views use .frame(idealWidth:480)) → no re-anchor → no jump.
        // ❌ NEVER change to [] — that is Architecture 2 (fixed heights) and breaks dynamic height.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        controller.sizingOptions = .preferredContentSize
        // Set initial frame width only. Height will be driven by preferredContentSize immediately.
        controller.view.frame = NSRect(origin: .zero, size: NSSize(width: Self.idealWidth, height: 0))
        hostingController = controller
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        // No contentSize set here — NSHostingController.preferredContentSize drives it.
        // ❌ NEVER set pop.contentSize manually — overrides preferredContentSize propagation.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(
                for: RunnerStore.shared.aggregateStatus
            )
            // In Architecture 1, store.reload() while popover is open is SAFE.
            // It triggers a SwiftUI layout pass → preferredContentSize.height updates →
            // dynamic height. Width stays at 480. No jump.
            // However, we still gate it to avoid double-updates during the open sequence.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    /// Resets navigation state after the popover closes.
    /// ❌ NEVER call reload() here — causes double-reload on next open.
    /// ❌ NEVER set contentSize here — not needed in Architecture 1.
    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - View factories

    /// nonisolated: called from DispatchQueue.global — pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated — required for background-queue call safety.
    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty
                || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

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

    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            },
            onLogLoaded: nil
        ))
    }

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

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            },
            onLogLoaded: nil
        ))
    }

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

    /// Swaps the hosting controller's root view. ZERO size changes. ZERO contentSize. Forever.
    /// With sizingOptions=.preferredContentSize, the new view's idealSize auto-propagates.
    /// Width stays at 480 (all views use idealWidth:480). Height updates to new content. No jump.
    /// ❌ NEVER add contentSize or setFrameSize here for any reason.
    /// ❌ NEVER call this from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover. Intentionally minimal — zero sizing logic.
    ///
    /// Dynamic height is driven by NSHostingController.preferredContentSize →
    /// NSPopover.contentSize auto-propagation via sizingOptions = .preferredContentSize.
    /// Width is stable at Self.idealWidth (480) because all views declare .frame(idealWidth:480).
    /// No contentSize.WIDTH change = no re-anchor = no side-jump. Ever.
    ///
    /// ❌ NEVER add setFrameSize here.
    /// ❌ NEVER add contentSize = here.
    /// ❌ NEVER add sizingOptions = [] here.
    /// ❌ NEVER measure fittingSize here (not needed in Architecture 1).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover
        else { return }
        popoverIsOpen = true
        observable.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
