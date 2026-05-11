import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #21 #13 #375 #376)
// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE ONE RULE THAT PREVENTS SIDE-JUMP:
//   contentSize must NEVER be written while popover.isShown == true,
//   EXCEPT when navigating back to mainView() (variable-height view).
//   ANY contentSize write while visible — even height-only — triggers a full
//   NSPopover re-anchor. This is a hardcoded AppKit constraint (issue #375).
//
// Architecture: AppKit-driven fixed-width, variable-height-on-main-only.
//   • openPopover() — reads fittingSize.height BEFORE show(), sets contentSize. Safe.
//   • navigate(to:shouldRemeasure:) — swaps rootView.
//       shouldRemeasure:true  → only for mainView() (back navigation). Remeasures after
//                               two async hops so SwiftUI finishes layout.
//       shouldRemeasure:false → for ALL detail/log/settings views. NO contentSize write.
//                               These views fill the fixed frame with ScrollView.
//   • remeasurePopover() — called ONLY from navigate(shouldRemeasure:true) and openPopover().
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER touch contentSize or setFrameSize anywhere except openPopover() and
//    remeasurePopover() (which is only called when shouldRemeasure == true).
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView
// ❌ NEVER use fittingSize.width anywhere — always use Self.fixedWidth.
//    fittingSize.width is non-deterministic when views with maxHeight:.infinity
//    are in the tree (e.g. StepLogView). Using it causes the side-jump (#13).
// ❌ NEVER wire onLogLoaded to remeasurePopover() — StepLogView uses
//    maxHeight:.infinity; fittingSize is non-deterministic there and calling
//    remeasurePopover() while the log view is shown causes a side-jump.
// ❌ NEVER collapse navigate(shouldRemeasure:true)'s two async hops to one —
//    SwiftUI needs two run-loop turns to fully commit and lay out mainView.
// ⚠️ fixedWidth MUST match PopoverMainView's .frame(idealWidth: 480).
//    Mismatching these causes fittingSize.height to be calculated at the
//    wrong width, wrapping content and producing an incorrect popover height.
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
    /// #22: Widened from 420 → 480 to give action-row titles more horizontal space
    /// and prevent truncation of multi-word workflow/job names.
    /// ❌ NEVER set this to a value other than 480 without also updating idealWidth
    ///    in PopoverMainView, SettingsView, JobDetailView, AND ActionDetailView.
    /// ❌ NEVER substitute Self.fixedWidth with fittingSize.width anywhere — see
    ///    regression guard above (#13 side-jump).
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private static let fixedWidth: CGFloat = 480

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
    /// ❌ NEVER call reload() here.
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
    ///
    /// ⚠️ mainView() is the ONLY destination that passes shouldRemeasure:true
    /// to navigate(). All other view factories pass shouldRemeasure:false (default).
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
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
                        // ⚠️ shouldRemeasure:false — forward nav into detail view.
                        // detail view fills the frame with ScrollView; no resize needed.
                        self.navigate(to: self.detailView(job: enriched), shouldRemeasure: false)
                    }
                }
            },
            onSelectAction: { [weak self] group in
                guard let self else { return }
                let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                // ⚠️ shouldRemeasure:false — forward nav into action detail view.
                self.navigate(to: self.actionDetailView(group: latest), shouldRemeasure: false)
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                // ⚠️ shouldRemeasure:false — settings fills the frame with ScrollView.
                self.navigate(to: self.settingsView(), shouldRemeasure: false)
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
                // ✅ shouldRemeasure:true — back to main, which has variable height.
                self.navigate(to: self.mainView(), shouldRemeasure: true)
            },
            onSelectJob: { [weak self] job in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.popoverIsOpen else { return }
                        // ⚠️ shouldRemeasure:false — forward nav into detail view.
                        self.navigate(
                            to: self.detailViewFromAction(job: enriched, group: group),
                            shouldRemeasure: false
                        )
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
                // ⚠️ shouldRemeasure:false — back to actionDetail, which also fills frame.
                self.navigate(to: self.actionDetailView(group: group), shouldRemeasure: false)
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                // ⚠️ shouldRemeasure:false — forward nav into log view.
                self.navigate(
                    to: self.logViewFromAction(job: job, step: step, group: group),
                    shouldRemeasure: false
                )
            }
        ))
    }

    /// Navigation level 4a: StepLogView reached via an ActionGroup.
    ///
    /// ❌ NEVER pass onLogLoaded a remeasurePopover() call.
    ///    StepLogView uses .frame(maxWidth:.infinity, maxHeight:.infinity).
    ///    fittingSize is non-deterministic there — calling remeasurePopover()
    ///    while the log view is shown causes a side-jump (issue #375).
    ///    The log content scrolls inside the fixed popover frame; no resize needed.
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
                // ⚠️ shouldRemeasure:false — back to detailFromAction, fills frame.
                self.navigate(
                    to: self.detailViewFromAction(job: job, group: group),
                    shouldRemeasure: false
                )
            },
            onLogLoaded: nil  // ❌ NO remeasure — see comment above
        ))
    }

    /// Navigation level 2: step list for a job (Jobs path).
    private func detailView(job: ActiveJob) -> AnyView {
        savedNavState = .jobDetail(job)
        return AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in
                guard let self else { return }
                // ✅ shouldRemeasure:true — back to main, which has variable height.
                self.navigate(to: self.mainView(), shouldRemeasure: true)
            },
            onSelectStep: { [weak self] step in
                guard let self else { return }
                // ⚠️ shouldRemeasure:false — forward nav into log view.
                self.navigate(to: self.logView(job: job, step: step), shouldRemeasure: false)
            }
        ))
    }

    /// Settings view.
    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                // ✅ shouldRemeasure:true — back to main, which has variable height.
                self.navigate(to: self.mainView(), shouldRemeasure: true)
            },
            store: observable
        ))
    }

    /// Navigation level 3: log output for a step (Jobs path).
    ///
    /// ❌ NEVER pass onLogLoaded a remeasurePopover() call.
    ///    StepLogView uses .frame(maxWidth:.infinity, maxHeight:.infinity).
    ///    fittingSize is non-deterministic there — calling remeasurePopover()
    ///    while the log view is shown causes a side-jump (issue #375).
    ///    The log content scrolls inside the fixed popover frame; no resize needed.
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
                // ⚠️ shouldRemeasure:false — back to jobDetail, fills frame.
                self.navigate(to: self.detailView(job: job), shouldRemeasure: false)
            },
            onLogLoaded: nil  // ❌ NO remeasure — see comment above
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

    /// Swaps the hosting controller's root view.
    ///
    /// shouldRemeasure:true  — ONLY for navigate-to-main (back button from any detail/log/settings).
    ///   Triggers remeasurePopover() after TWO async hops so SwiftUI finishes laying out
    ///   the variable-height main view before contentSize is updated.
    ///   WHY TWO HOPS:
    ///     Hop 1 — SwiftUI commits the new rootView (replaces the view tree).
    ///     Hop 2 — SwiftUI completes the full layout pass for the new tree,
    ///              including inner ForEach, ScrollView content, PopoverLocalRunnerRow, etc.
    ///     Sampling on hop 1 returns a partial/stale height → wrong popover size.
    ///
    /// shouldRemeasure:false — for ALL forward navigation (main→detail, detail→log, etc.)
    ///   and back navigation between fixed-height views (detail↔actionDetail).
    ///   NO contentSize write. These views fill the fixed frame with their ScrollView.
    ///   Writing contentSize while they are visible triggers NSPopover re-anchor = jump.
    ///
    /// ❌ NEVER pass shouldRemeasure:true for any destination other than mainView().
    /// ❌ NEVER collapse shouldRemeasure:true's two async hops to one.
    /// ❌ NEVER call this from a background thread.
    /// ❌ NEVER read fittingSize.width — remeasurePopover always uses Self.fixedWidth.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView, shouldRemeasure: Bool = false) {
        hostingController?.rootView = view
        guard shouldRemeasure,
              let _ = hostingController,
              let popover,
              popover.isShown else { return }
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.remeasurePopover()
            }
        }
    }

    /// Re-measures height via fittingSize and resizes the popover.
    /// Called ONLY when navigating back to mainView() and from openPopover().
    /// Width is ALWAYS Self.fixedWidth — never fittingSize.width.
    ///
    /// ❌ NEVER call from any navigate() call with shouldRemeasure:false.
    /// ❌ NEVER substitute Self.fixedWidth with fittingSize.width — causes #13 side-jump.
    /// ❌ NEVER call from a background thread.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func remeasurePopover() {
        guard let hc = hostingController,
              let pop = popover,
              pop.isShown else { return }
        let newHeight = hc.view.fittingSize.height
        guard newHeight > 0 else { return }
        let newSize = NSSize(width: Self.fixedWidth, height: newHeight)
        hc.view.setFrameSize(newSize)
        pop.contentSize = newSize
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

    /// Opens the popover. Sets contentSize BEFORE show() — the only safe moment.
    ///
    /// fittingSize.HEIGHT is read synchronously here before show() is called.
    /// This is safe because popover.isShown is still false at this point —
    /// writing contentSize before show() does NOT trigger a re-anchor (issue #375 Option 3).
    /// Width is always Self.fixedWidth — never fittingSize.width.
    ///
    /// ❌ NEVER use fittingSize.width here — always Self.fixedWidth.
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
        let size = NSSize(
            width: Self.fixedWidth,                            // ❌ NEVER fittingSize.width
            height: hostingController.view.fittingSize.height  // ✅ safe — popover not yet shown
        )
        hostingController.view.setFrameSize(size)
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored, shouldRemeasure: false)
        }
    }
}
// swiftlint:enable type_body_length
