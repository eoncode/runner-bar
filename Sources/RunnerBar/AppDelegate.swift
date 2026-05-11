import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #21 #13 #375 #376 #377)
// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE ONLY CORRECT ARCHITECTURE (proven by main branch, SHA e6bb42e + issue #377):
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//   openPopover() = the ONE site where contentSize is set, BEFORE show() is called.
//                   Safe because popover.isShown == false at that point.
//
//   CRITICAL: controller.sizingOptions = [] MUST be set on NSHostingController.
//   Without it, the default .preferredContentSize auto-propagates contentSize to
//   the popover on EVERY SwiftUI layout pass (including the 5s runnerRefreshTimer
//   and every onChange) — each propagation while isShown==true = side-jump.
//   This is the root cause confirmed by Just10/MEMORY.md and issue #377.
//
// OPEN SEQUENCE — must match this order exactly (❌ do NOT reorder steps):
//   1. popoverIsOpen = true
//   2. observable.reload()          ← loads live data into mainView()
//   3. fittingSize.height           ← reads the MEASURING VIEW with live data.
//                                      For most states: mainView().
//                                      For settings/detail restores: the restored view itself.
//   4. rootView = mainView()        ← reset root to mainView() BEFORE show()
//                                      Required: mainView() must be root at show() time
//                                      so the popover anchor is stable.
//   5. setFrameSize + contentSize   ← safe: popover.isShown == false
//   6. show()                       ← popover becomes visible HERE
//   7. navigate(to: restored)       ← rootView swap AFTER show. Zero sizing. Safe.
//                                      navigate() never touches contentSize. Ever.
//
// WHY sizingOptions = [] is load-bearing:
//   Default NSHostingController.sizingOptions = .preferredContentSize.
//   With .preferredContentSize, every SwiftUI state update (store.reload(),
//   timer ticks, @State changes) causes the hosting controller to call
//   setPreferredContentSize on its parent NSPopover. NSPopover re-anchors
//   on every contentSize change while shown. Result: side-jump every 5s.
//   With sizingOptions = [], the hosting controller NEVER touches contentSize.
//   Only openPopover() sets contentSize, and only before show().
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER remove the sizingOptions = [] line
// ❌ NEVER add contentSize or setFrameSize to navigate() for any reason
// ❌ NEVER call remeasurePopover() from onLogLoaded or any post-navigation callback
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView
// ❌ NEVER use fittingSize.width — always use Self.fixedWidth.
//    fittingSize.width is non-deterministic when maxHeight:.infinity is in tree.
// ❌ NEVER wire onLogLoaded to any contentSize write.
//    StepLogView uses maxHeight:.infinity. fittingSize is non-deterministic there.
// ❌ NEVER read fittingSize AFTER navigate(to: restored) — restoring first causes
//    fittingSize to read from StepLogView root where it returns 0.
// ❌ NEVER move navigate(to: restored) before show() — it belongs AFTER show().
// ❌ NEVER restore stepLog or actionStepLog via savedNavState.
//    StepLogView: maxHeight:.infinity → fittingSize = 0 before log loads.
// ⚠️ fixedWidth MUST match PopoverMainView's .frame(idealWidth: 480).
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
        // ❌ CRITICAL — DO NOT REMOVE THIS LINE. EVER.
        // sizingOptions = [] prevents NSHostingController from auto-propagating
        // preferredContentSize to the popover on every SwiftUI layout pass.
        // Without this, every store.reload(), timer tick, or @State change while
        // the popover is shown triggers a contentSize write → NSPopover re-anchor
        // → side-jump. This is the root cause documented in issue #377 and
        // confirmed by Just10/MEMORY.md (another SwiftUI status bar app with the
        // same bug history). The default NSHostingController.sizingOptions is
        // .preferredContentSize — that default is wrong for NSPopover usage.
        // Dynamic height is preserved: fittingSize is read fresh in openPopover()
        // before show(), so height still varies per open based on live content.
        // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
        // comment is removed is major major major.
        controller.sizingOptions = []
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
    ///    Fall back to the parent detail view instead.
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
    /// ❌ NEVER reorder these steps. Each ordering decision is load-bearing.
    ///
    ///   Step 1-2: reload() loads live data into mainView().
    ///   Step 3:   Determine the measuring view:
    ///             - For Settings/Detail restores: temporarily swap rootView to the
    ///               restored view and read its fittingSize.height. This gives the
    ///               correct tall height for Settings/Detail instead of mainView()'s
    ///               short height (which would clip Settings content).
    ///             - For all other states (main, stepLog fallbacks): read from mainView().
    ///             StepLog states are always excluded — fittingSize=0 before async load.
    ///   Step 4:   rootView = mainView() — reset root BEFORE show(). Load-bearing:
    ///             mainView() must be root at show() time (proven zero-regression pattern).
    ///   Step 5:   setFrameSize + contentSize BEFORE show() — safe, isShown==false.
    ///   Step 6:   show() — popover becomes visible.
    ///   Step 7:   navigate(to: restored) AFTER show() — pure rootView swap, zero sizing.
    ///
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
    /// ❌ NEVER call setFrameSize or set contentSize after show().
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }

        // Steps 1-2.
        popoverIsOpen = true
        observable.reload()

        // Step 3: choose the measuring view.
        // For Settings and fittingSize-safe detail states, temporarily install the
        // restored view as root and measure it. This gives the correct height for
        // those views instead of mainView()'s short height.
        // For all other states, mainView() (already installed) is measured directly.
        //
        // ❌ NEVER measure StepLog states — maxHeight:.infinity → fittingSize=0.
        // ❌ NEVER move the rootView reset (step 4) before this measurement.
        let measureFromRestored: Bool
        switch savedNavState {
        case .settings, .jobDetail, .actionDetail, .actionJobDetail:
            measureFromRestored = true
        default:
            measureFromRestored = false
        }

        var restoredView: AnyView?
        if measureFromRestored, let saved = savedNavState {
            // Temporarily install restored view to read its fittingSize.
            // validatedView() sets savedNavState = nil as a side effect,
            // so we capture the restored view reference before show().
            restoredView = validatedView(for: saved)
            if let rv = restoredView {
                hostingController.rootView = rv
            }
        }

        let rawHeight = hostingController.view.fittingSize.height

        // Step 4: reset root to mainView() BEFORE show() — proven stable anchor pattern.
        // If we measured from a restored view above, this resets back so show()
        // anchors from the standard mainView() root.
        hostingController.rootView = mainView()

        // Height: clamped [minHeight, maxHeight]. Falls back to 300 if 0 (empty state).
        // Width: always fixedWidth — fittingSize.width non-deterministic w/ maxHeight:.infinity.
        let height = min(max(rawHeight > 0 ? rawHeight : 300, Self.minHeight), Self.maxHeight)
        let size = NSSize(width: Self.fixedWidth, height: height)

        // Step 5: size before show — safe.
        hostingController.view.setFrameSize(size)
        popover.contentSize = size

        // Step 6: show.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        // Step 7: restore nav state AFTER show — pure rootView swap, zero sizing.
        // If we pre-built restoredView above, reuse it. Otherwise check savedNavState
        // (covers the non-measured restore path: .stepLog falls back to detailView).
        if let rv = restoredView {
            navigate(to: rv)
        } else if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
