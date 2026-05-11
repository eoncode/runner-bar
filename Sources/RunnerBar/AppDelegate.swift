import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE CORRECT ARCHITECTURE — mirrors main branch (zero-regression, SHA e6bb42e):
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//
//   openPopover() = calls show() only. NO manual contentSize. NO setFrameSize.
//                   NSHostingController.preferredContentSize auto-propagates to
//                   the popover as SwiftUI renders. Height is always correct
//                   because it reflects actual rendered content.
//
//   sizingOptions = .preferredContentSize (DEFAULT — do NOT override to []).
//   This is the key insight: .preferredContentSize lets NSHostingController
//   drive height dynamically. Width never varies because ALL views have
//   .frame(idealWidth: 480) — so preferredContentSize.width is always 480.
//   Width = constant = zero re-anchor = zero side-jump.
//   Height = dynamic = correct for any content state = no empty space, no clipping.
//
//   WHY sizingOptions = [] IS WRONG FOR THIS CODEBASE:
//   [] prevents NSHostingController from auto-propagating preferredContentSize.
//   Manual fittingSize measurement in openPopover() is then required for height.
//   But fittingSize is measured synchronously BEFORE SwiftUI has rendered the
//   data from observable.reload() (which triggers async @ObservedObject updates).
//   Result: height is measured on stale content = wrong height = empty space.
//   This is the oscillation trap: fixing jump with [] breaks height; fixing height
//   with dynamic measurement brings back jump. The escape is NOT to suppress sizing.
//
//   WHY WIDTH NEVER JUMPS (the only real constraint):
//   NSPopover re-anchors when contentSize.WIDTH changes. Height changes are safe.
//   preferredContentSize.width is stable at 480 because every view in the entire
//   navigation tree — PopoverMainView, SettingsView, JobDetailView,
//   ActionDetailView, StepLogView — ALL declare .frame(idealWidth: 480).
//   .frame(idealWidth: 480) tells SwiftUI its ideal/preferred width is 480.
//   NSHostingController reads this as preferredContentSize.width = 480.
//   If ANY view uses a different idealWidth, navigating to it changes width = jump.
//   If ANY view omits idealWidth entirely, preferredContentSize.width becomes
//   non-deterministic (can be 0, screen width, or anything) = jump.
//
//   WHY THE TIMER GUARD IS CRITICAL:
//   The 5s timer in PopoverMainView calls store.reload() which mutates
//   @ObservedObject store — triggering a SwiftUI layout pass. That layout
//   pass updates preferredContentSize. With sizingOptions = .preferredContentSize,
//   that triggers a contentSize write on the popover. While popover.isShown,
//   a contentSize write = NSPopover re-anchor = side-jump every 5s.
//   The guard: if !isPopoverOpen { store.reload() } in the timer prevents
//   any layout pass while the popover is shown.
//   ❌ NEVER call store.reload() while popoverIsOpen == true.
//   ❌ NEVER remove the isPopoverOpen guard from the timer.
//
//   OPEN SEQUENCE (correct order, do NOT reorder):
//   1. popoverIsOpen = true
//   2. observable.reload()       ← loads live data
//   3. show()                    ← NSHostingController renders with live data
//                                   preferredContentSize propagates after render
//   4. navigate(to: restored)    ← rootView swap AFTER show. Zero sizing. Safe.
//   Height auto-corrects after SwiftUI renders. No manual measurement needed.
//
// ❌ NEVER set sizingOptions = [] — breaks height (see above)
// ❌ NEVER manually set contentSize anywhere (the initial placeholder was REMOVED
//    in commit #377 — it caused the fixed-300pt-height regression)
// ❌ NEVER call setFrameSize in openPopover()
// ❌ NEVER use fittingSize.width — non-deterministic with maxWidth:.infinity
// ❌ NEVER add contentSize or setFrameSize to navigate()
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from ANY view in the nav tree
// ❌ NEVER use a different idealWidth value in ANY view (must all be 480)
// ❌ NEVER call store.reload() while popoverIsOpen == true
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded
//    Called from DispatchQueue.global — pure network I/O, no @MainActor state
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView has maxHeight:.infinity — preferredContentSize.height = 0
//    before log loads, causing a collapsed popover if restored
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
    /// ❌ NEVER use this for contentSize.height — height is driven by preferredContentSize.
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
        // Set the view frame width to idealWidth so the first SwiftUI layout pass
        // measures content at the correct width. Height is left at 0 so the first
        // preferredContentSize propagation (driven by sizingOptions = .preferredContentSize,
        // the NSHostingController default) immediately wins without fighting a hardcoded
        // placeholder.
        //
        // ❌ NEVER set a fixed height here (e.g. height: 300) — it locks the popover
        //    at that height until the first preferredContentSize update fires, which is
        //    the "fixed height" regression (issue #377).
        // ❌ NEVER set popover.contentSize manually here — same regression.
        // ❌ NEVER add sizingOptions = [] here — breaks height propagation.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        controller.view.frame = NSRect(origin: .zero, size: NSSize(width: Self.idealWidth, height: 0))
        hostingController = controller
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(
                for: RunnerStore.shared.aggregateStatus
            )
            // ❌ NEVER call observable.reload() while popoverIsOpen == true.
            // reload() → @ObservedObject mutation → SwiftUI layout pass →
            // preferredContentSize update → contentSize write on popover →
            // NSPopover re-anchor → side-jump.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    /// Resets navigation state after the popover closes.
    /// ❌ NEVER call reload() here — causes double-reload on next open.
    /// ❌ NEVER set contentSize here — re-anchor regression.
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
    /// NSHostingController.preferredContentSize updates automatically via sizingOptions.
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
    /// Width is stable at Self.idealWidth because all views declare .frame(idealWidth: 480).
    /// No re-anchor because contentSize.WIDTH never changes.
    ///
    /// ❌ NEVER add setFrameSize here.
    /// ❌ NEVER add contentSize = here.
    /// ❌ NEVER add sizingOptions = [] before show() — breaks height propagation.
    /// ❌ NEVER call store.reload() or observable.reload() after show() — layout pass = re-anchor.
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
