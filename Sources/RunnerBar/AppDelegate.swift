import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  POPOVER SIZING — REGRESSION GRAVEYARD  ☠️                              ║
// ║  Every rule below was learned by breaking the app. Do NOT remove any of     ║
// ║  them. Do NOT "just try" touching contentSize. Read all of this first.      ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║                                                                              ║
// ║  HOW SIZING WORKS (the ONLY correct model):                                 ║
// ║    1. openPopover() fires once. It calls fittingSize on the hosting view,   ║
// ║       sets hostingController.view.frame + popover.contentSize, then shows.  ║
// ║    2. After that: NOTHING touches the size. Ever. For any reason.           ║
// ║    3. navigate() = ONE LINE: hostingController?.rootView = view             ║
// ║       That is the complete function. Nothing else belongs there.            ║
// ║                                                                              ║
// ║  ISSUE #13 — SIDE-JUMP REGRESSION (introduced and fixed 2026-05-10):       ║
// ║    WHAT BROKE: A "remeasurePopover()" function was added that called        ║
// ║      hc.view.setFrameSize(newSize) and pop.contentSize = newSize while      ║
// ║      popover.isShown == true. It was wired to TWO call sites:               ║
// ║        (a) navigate() via DispatchQueue.main.async — fired on EVERY         ║
// ║            navigation (main→detail, detail→log, back, settings, etc.)       ║
// ║        (b) StepLogView.onLogLoaded — fired after the async log fetch        ║
// ║            completed and isLoading flipped to false.                        ║
// ║    WHY IT BROKE: AppKit recomputes the popover's screen anchor position     ║
// ║      whenever contentSize changes while the popover is visible. This        ║
// ║      caused the popover window to jump sideways on screen every single      ║
// ║      navigation tap and every log load. The status-bar button anchor was    ║
// ║      correct but the popover repositioned itself against the new size.      ║
// ║    THE FIX: Delete remeasurePopover() entirely. Remove onLogLoaded from     ║
// ║      every StepLogView instantiation. Revert navigate() to one line.       ║
// ║    WHY onLogLoaded IS NOT NEEDED: StepLogView already uses                  ║
// ║      .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top) and    ║
// ║      wraps log content in a ScrollView. The popover height set at open      ║
// ║      time is sufficient; the ScrollView absorbs log content of any length.  ║
// ║                                                                              ║
// ║  ABSOLUTE RULES — violation = side-jump or broken sizing:                  ║
// ║    ❌ NEVER call setFrameSize while popover.isShown == true                 ║
// ║    ❌ NEVER set popover.contentSize while popover.isShown == true           ║
// ║    ❌ NEVER add DispatchQueue.main.async (or any async) inside navigate()   ║
// ║    ❌ NEVER add a remeasurePopover() function or equivalent                 ║
// ║    ❌ NEVER wire onLogLoaded (or any post-load callback) to a resize        ║
// ║    ❌ NEVER set sizingOptions = .preferredContentSize                       ║
// ║    ❌ NEVER add objectWillChange.send() in reload()                         ║
// ║    ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView             ║
// ║    ❌ NEVER change fixedWidth without also changing idealWidth in           ║
// ║       PopoverMainView AND SettingsView (fittingSize height is computed      ║
// ║       at fixedWidth; mismatch wraps text and produces wrong height)         ║
// ║                                                                              ║
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
    private var popoverIsOpen = false

    /// Fixed popover width — MUST match PopoverMainView's .frame(idealWidth: 480).
    /// #22: Widened from 420 → 480 to give action-row titles more horizontal space
    /// and prevent truncation of multi-word workflow/job names.
    /// ❌ NEVER change this value without also updating idealWidth in
    ///    PopoverMainView AND SettingsView — see REGRESSION GRAVEYARD above.
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
    /// ❌ NEVER call reload() here — it triggers objectWillChange on a closed popover.
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
    /// ☠️ REGRESSION TOUCHPOINT (issue #13):
    ///   An `onLogLoaded` closure was previously passed here that called
    ///   `remeasurePopover()` → `setFrameSize` + `contentSize = newSize` while
    ///   the popover was shown. This caused the popover to jump sideways on screen
    ///   every time a log finished loading. It is gone. Do NOT bring it back.
    ///   StepLogView's ScrollView handles variable-length log content internally.
    ///   No popover resize is needed, safe, or permitted after open.
    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
            // ☠️ NO onLogLoaded — see docstring above and REGRESSION GRAVEYARD at top of file.
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
    /// ☠️ REGRESSION TOUCHPOINT (issue #13):
    ///   Same as logViewFromAction — an `onLogLoaded` resize closure was wired here
    ///   and caused the popover to jump on every log load. Removed. Do NOT add it back.
    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
            // ☠️ NO onLogLoaded — see docstring above and REGRESSION GRAVEYARD at top of file.
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

    // ╔══════════════════════════════════════════════════════════════════════════╗
    // ║  ☠️  navigate() — THIS IS THE COMPLETE FUNCTION. ONE LINE. FOREVER.  ☠️  ║
    // ╠══════════════════════════════════════════════════════════════════════════╣
    // ║  REGRESSION TOUCHPOINT (issue #13):                                     ║
    // ║    Previously this function contained:                                  ║
    // ║      hostingController?.rootView = view          ← correct              ║
    // ║      guard ..., popover.isShown else { return }  ← wrong, led to:       ║
    // ║      DispatchQueue.main.async {                  ← ☠️ CAUSED SIDE-JUMP   ║
    // ║          self?.remeasurePopover()                ← ☠️ CAUSED SIDE-JUMP   ║
    // ║      }                                           ← ☠️ CAUSED SIDE-JUMP   ║
    // ║    The async block ran after every single navigation tap and called      ║
    // ║    setFrameSize + contentSize while the popover was visible, which       ║
    // ║    caused AppKit to recompute the anchor → popover jumped sideways.     ║
    // ║                                                                          ║
    // ║  ❌ NEVER add DispatchQueue.main.async here                              ║
    // ║  ❌ NEVER call remeasurePopover() or any equivalent                      ║
    // ║  ❌ NEVER touch setFrameSize or contentSize here                         ║
    // ║  ❌ NEVER add a guard + isShown branch that leads to a resize            ║
    // ╚══════════════════════════════════════════════════════════════════════════╝
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

    /// Opens the popover. The ONE and ONLY safe site for setFrameSize and contentSize.
    /// These calls are safe here because the popover is not yet shown when they fire.
    /// ❌ NEVER replicate this sizing logic anywhere else in this file.
    /// ❌ NEVER call setFrameSize or contentSize from navigate(), onLogLoaded,
    ///    or any callback that fires while popover.isShown == true.
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
