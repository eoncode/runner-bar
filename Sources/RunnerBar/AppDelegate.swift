import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #21 #13 #375 #376)
// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE ONLY CORRECT ARCHITECTURE (proven by main branch):
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//   openPopover() = the ONE site where contentSize is set, BEFORE show() is called.
//                   Safe because popover.isShown == false at that point.
//
// OPEN SEQUENCE (MUST follow this order):
//   1. popoverIsOpen = true
//   2. observable.reload()
//   3. If savedNavState: navigate(to: restored) FIRST — so fittingSize reflects the
//      restored view, not mainView.
//   4. hostingController.view.fittingSize.height  ← read AFTER rootView is correct
//   5. hostingController.view.setFrameSize(size)
//   6. popover.contentSize = size
//   7. popover.show(...)  ← LAST. Nothing touches sizing after this line. Ever.
//
// ANY contentSize write (or setFrameSize) while popover.isShown == true triggers
// a full NSPopover re-anchor. This is a hardcoded AppKit constraint (issue #375).
// This includes: height-only writes, writes from async callbacks, writes from
// onLogLoaded, and writes from back-navigation. ALL of them cause side-jump.
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER add contentSize or setFrameSize to navigate() for any reason
// ❌ NEVER call remeasurePopover() from onLogLoaded or any post-navigation callback
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView
// ❌ NEVER use fittingSize.width anywhere — always use Self.fixedWidth.
//    fittingSize.width is non-deterministic when maxHeight:.infinity is in tree
//    (e.g. StepLogView). Using it causes the side-jump (#13).
// ❌ NEVER wire onLogLoaded to remeasurePopover().
//    StepLogView uses maxHeight:.infinity. fittingSize is non-deterministic there.
//    Calling contentSize while log view is shown = re-anchor = side-jump (#375).
//    The log content scrolls inside the fixed frame set by openPopover(). Safe.
// ⚠️ fixedWidth MUST match PopoverMainView's .frame(idealWidth: 480).
// ❌ NEVER restore stepLog or actionStepLog via savedNavState on open.
//    StepLogView uses maxHeight:.infinity -> fittingSize.height == 0 when
//    loaded as root before content is fetched -> popover opens with zero height.
// ❌ NEVER read fittingSize BEFORE navigate(to: restored).
//    fittingSize reflects the current rootView. If mainView() is still root when
//    fittingSize is read, the height will be mainView's height — not the restored
//    view's height. Always restore first, then measure.
// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

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
    // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    // is major major major.
    private var popoverIsOpen = false

    /// Fixed popover width — MUST match PopoverMainView's .frame(idealWidth: 480).
    /// #22: Widened from 420 → 480 to give action-row titles more horizontal space.
    /// ❌ NEVER set this to a value other than 480 without also updating idealWidth
    ///    in PopoverMainView, SettingsView, JobDetailView, AND ActionDetailView.
    /// ❌ NEVER substitute Self.fixedWidth with fittingSize.width anywhere.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private static let fixedWidth: CGFloat = 480
    private static let minHeight:  CGFloat = 120
    private static let maxHeight:  CGFloat = 620

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
            // ❌ NEVER touch contentSize / setFrameSize here — fires while popover
            // is shown → re-anchor → side-jump (Regression A, issue #375).
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    /// Resets navigation state after the popover closes.
    /// ❌ NEVER call reload() here.
    /// ❌ NEVER set contentSize here.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
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
    /// ❌ NEVER wire onLogLoaded to remeasurePopover() or any contentSize write.
    ///    StepLogView uses maxHeight:.infinity. fittingSize is non-deterministic
    ///    there. Any contentSize write while the log view is visible triggers a
    ///    full NSPopover re-anchor — the side-jump regression (issue #375).
    ///    The log content scrolls inside the fixed frame set by openPopover().
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            },
            onLogLoaded: nil  // ❌ NEVER wire to remeasurePopover() — see above
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
    /// ❌ NEVER wire onLogLoaded to remeasurePopover() or any contentSize write.
    ///    StepLogView uses maxHeight:.infinity. Any contentSize write while the
    ///    log view is visible = re-anchor = side-jump (issue #375).
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            },
            onLogLoaded: nil  // ❌ NEVER wire to remeasurePopover() — see above
        ))
    }

    /// Returns a refreshed view for `state` using live RunnerStore data, or `nil` if stale.
    ///
    /// ❌ NEVER restore stepLog or actionStepLog states.
    ///    StepLogView uses maxHeight:.infinity → fittingSize.height == 0 when
    ///    it is the root view before its async log fetch completes.
    ///    openPopover() would then set contentSize.height = 0 → zero-height popover.
    ///    Force the user back to the parent detail view instead.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil
        let store = RunnerStore.shared
        switch state {
        case .main:
            return nil
        case .jobDetail(let job):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return detailView(job: live)
        case .stepLog(let job, _):
            // ❌ Do NOT restore to StepLogView — fittingSize == 0, zero-height popover.
            // Fall back to the parent JobDetailView instead.
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return detailView(job: live)
        case .actionDetail(let group):
            guard let live = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return actionDetailView(group: live)
        case .actionJobDetail(let job, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return detailViewFromAction(job: liveJob, group: liveGroup)
        case .actionStepLog(let job, _, let group):
            // ❌ Do NOT restore to StepLogView — fittingSize == 0, zero-height popover.
            // Fall back to the parent ActionJobDetailView instead.
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            let liveJob = liveGroup.jobs.first(where: { $0.id == job.id }) ?? job
            return detailViewFromAction(job: liveJob, group: liveGroup)
        case .settings:
            return settingsView()
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's root view. ZERO size changes. Forever.
    ///
    /// ❌ NEVER add contentSize or setFrameSize here for any reason.
    /// ❌ NEVER add a shouldRemeasure parameter — any remeasure while popover.isShown
    ///    triggers NSPopover re-anchor → side-jump (issue #375).
    /// ❌ NEVER call this from a background thread.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
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

    /// Opens the popover. The ONE site where contentSize is written.
    ///
    /// CRITICAL SEQUENCE — order is non-negotiable (ref #375, main branch):
    ///   1. popoverIsOpen = true
    ///   2. observable.reload()
    ///   3. navigate(to: restored) if savedNavState — BEFORE reading fittingSize.
    ///      Reason: fittingSize reflects the current rootView. If mainView() is
    ///      still root, fittingSize returns mainView's height, not the restored
    ///      view's height. Restoring first ensures fittingSize is correct.
    ///   4. Read fittingSize.height — now reflects the actual view to be shown.
    ///   5. setFrameSize + contentSize — safe, popover.isShown == false.
    ///   6. show() — LAST. Nothing touches sizing after this. Ever.
    ///
    /// ❌ NEVER read fittingSize before navigate(to: restored).
    /// ❌ NEVER use fittingSize.width here — always Self.fixedWidth.
    /// ❌ NEVER call setFrameSize or set contentSize after show() is called.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }
        popoverIsOpen = true
        observable.reload()

        // Step 3: Restore saved nav state FIRST — so fittingSize reflects the
        // correct view, not mainView().
        // ❌ NEVER move this after the fittingSize read.
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        // Step 4: Read fittingSize AFTER rootView is set to the actual view.
        // Width: always fixedWidth (fittingSize.width is non-deterministic w/ maxHeight:.infinity).
        // Height: clamp to [minHeight, maxHeight]. If still 0 (e.g. StepLogView root
        //   that slipped through validatedView), fall back to maxHeight.
        let rawHeight = hostingController.view.fittingSize.height
        let height = min(max(rawHeight > 0 ? rawHeight : Self.maxHeight, Self.minHeight), Self.maxHeight)
        let size = NSSize(width: Self.fixedWidth, height: height)

        // Steps 5–6: size then show — safe because popover.isShown == false.
        hostingController.view.setFrameSize(size)
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
// swiftlint:enable type_body_length
