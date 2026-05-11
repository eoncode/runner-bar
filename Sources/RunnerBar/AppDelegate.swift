import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #21 #13)
// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// sizingOptions: default. Height read via fittingSize ONCE per open.
// navigate() = rootView swap + ONE async remeasurePopover() hop ONLY.
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER touch contentSize or setFrameSize synchronously while popover.isShown == true
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView
// ❌ NEVER use fittingSize.width anywhere — always use Self.fixedWidth.
//     fittingSize.width is non-deterministic when views with maxHeight:.infinity
//     are in the tree (e.g. StepLogView). Using it causes the popover to shift
//     horizontally — the side-jump regression (issue #13).
// ⚠️ fixedWidth MUST match PopoverMainView's .frame(idealWidth: 480).
//     Mismatching these causes fittingSize.height to be calculated at the
//     wrong width, wrapping content and producing an incorrect popover height.
//
// #21: StepLogView calls onLogLoaded() once the async log fetch completes.
//     AppDelegate wires onLogLoaded to a TWO-HOP async remeasurePopover():
//
//       onLogLoaded fires (main thread, isLoading just flipped false)
//         └─ DispatchQueue.main.async (hop 1: SwiftUI commits isLoading=false)
//              └─ DispatchQueue.main.async (hop 2: SwiftUI lays out log Text)
//                   └─ remeasurePopover()  ← fittingSize now reflects log height
//
//     ONE hop is insufficient: fittingSize still reflects the spinner height on
//     the first run-loop turn after isLoading flips false. Two hops give SwiftUI
//     two full run-loop turns to commit the new log layout before sampling.
//     Width is always Self.fixedWidth — never fittingSize.width — to prevent #13.
//     If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//     UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//     is major major major.
//
// #13 SIDE-JUMP FIX (openPopover):
//     The popover is shown at (fixedWidth × lastKnownHeight) — never sampling
//     fittingSize synchronously before show(). fittingSize before the first
//     layout pass is unreliable (especially with maxHeight:.infinity in the tree),
//     which caused AppKit to compute the wrong anchor X and shift the popover
//     horizontally. After show() we fire ONE async hop so SwiftUI completes its
//     first layout pass, then call remeasurePopover() to correct the height.
//     Width stays fixedWidth throughout — never fittingSize.width.
//     ❌ NEVER revert to synchronous fittingSize sampling before show().
//     ❌ NEVER use fittingSize.width here or in remeasurePopover().
//     If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//     UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//     is major major major.

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
    ///    in PopoverMainView AND SettingsView.
    /// ❌ NEVER substitute Self.fixedWidth with fittingSize.width anywhere — see
    ///    regression guard above (#13 side-jump).
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private static let fixedWidth: CGFloat = 480

    /// Last known good popover height, used as the stable initial size when opening.
    /// Avoids a synchronous fittingSize sample before show() which is unreliable
    /// and causes the #13 horizontal side-jump. Updated by remeasurePopover().
    /// ❌ NEVER replace with fittingSize.height sampled before show().
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private var lastKnownHeight: CGFloat = 300

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
        let initialSize = NSSize(width: Self.fixedWidth, height: lastKnownHeight)
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
    /// #21: onLogLoaded uses TWO async hops — see regression guard at top of file.
    /// ❌ NEVER collapse to one hop — fittingSize reflects spinner on the first turn.
    /// ❌ NEVER use fittingSize.width inside remeasurePopover — always Self.fixedWidth.
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
            onLogLoaded: { [weak self] in
                guard let self else { return }
                // #21: Two async hops so SwiftUI has two run-loop turns to commit
                // the log layout before fittingSize is sampled. ONE hop is not enough.
                // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
                // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
                // comment is removed is major major major.
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        self.remeasurePopover()
                    }
                }
            }
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
    /// #21: onLogLoaded uses TWO async hops — see regression guard at top of file.
    /// ❌ NEVER collapse to one hop — fittingSize reflects spinner on the first turn.
    /// ❌ NEVER use fittingSize.width inside remeasurePopover — always Self.fixedWidth.
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
            onLogLoaded: { [weak self] in
                guard let self else { return }
                // #21: Two async hops so SwiftUI has two run-loop turns to commit
                // the log layout before fittingSize is sampled. ONE hop is not enough.
                // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
                // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
                // comment is removed is major major major.
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        self.remeasurePopover()
                    }
                }
            }
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

    /// Swaps the hosting controller's root view, then remeasures the popover height
    /// on the next run-loop turn so SwiftUI has laid out the new content.
    ///
    /// ❌ NEVER move the resize into the synchronous part of this function.
    /// ❌ NEVER call this from a background thread.
    /// ❌ NEVER read fittingSize.width here — remeasurePopover always uses Self.fixedWidth.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
        guard let hostingController, let popover, popover.isShown else { return }
        DispatchQueue.main.async { [weak self] in
            self?.remeasurePopover()
        }
    }

    /// Re-measures height via fittingSize and resizes the popover.
    /// Width is ALWAYS Self.fixedWidth — never fittingSize.width.
    /// Also persists the new height in lastKnownHeight so the next open
    /// can use a stable size without a synchronous fittingSize sample.
    ///
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
        lastKnownHeight = newHeight
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

    /// Opens the popover at (fixedWidth × lastKnownHeight), then remeasures height
    /// asynchronously after SwiftUI's first layout pass completes.
    ///
    /// Using lastKnownHeight instead of a synchronous fittingSize sample prevents the
    /// #13 horizontal side-jump: fittingSize before the first layout pass is
    /// unreliable (especially with maxHeight:.infinity views in the tree such as
    /// StepLogView), causing AppKit to compute the wrong anchor X position.
    ///
    /// ❌ NEVER sample fittingSize synchronously before pop.show() — causes #13.
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
        // #13: Use lastKnownHeight — NOT fittingSize.height — as the initial size.
        // fittingSize before show() is unreliable and causes horizontal side-jump.
        let size = NSSize(width: Self.fixedWidth, height: lastKnownHeight)
        hostingController.view.setFrameSize(size)
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        // Remeasure height after SwiftUI's first layout pass so the popover
        // correctly sizes to the actual content without shifting horizontally.
        DispatchQueue.main.async { [weak self] in
            self?.remeasurePopover()
        }
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
