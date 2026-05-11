import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #377)
//
// ARCHITECTURE: Architecture 2 (AppKit-driven / sizingOptions = [])
// Confirmed correct by issue #377, Just10/MEMORY.md, status-bar-app-position-warning.md
//
// Rules (ALL must hold simultaneously):
//   sizingOptions = []        — NEVER .preferredContentSize.
//                               .preferredContentSize auto-pushes on every SwiftUI
//                               layout pass while shown → re-anchor → left jump.
//   openPopover()             — the ONE place contentSize is set.
//                               Two-phase open: phase 1 stages the view and data;
//                               phase 2 runs on the next runloop tick AFTER SwiftUI
//                               has settled layout, reads fittingSize, sets contentSize,
//                               then calls show(). This gives TRUE dynamic height without
//                               any sizing call after show() — no side-jump possible.
//   navigate()                — rootView swap ONLY. ZERO size changes. Forever.
//   .frame(width: 420)        — MUST wrap every non-main nav-state view.
//                               With sizingOptions=[] SwiftUI does not auto-push
//                               width, so each view must declare its own width or
//                               it collapses to zero → layout crash in Settings.
//   onChange / polling        — NEVER touches sizing. Status icon update only.
//
// ❌ NEVER set popover.contentSize anywhere except openPopover() before show()
// ❌ NEVER call hc.view.setFrameSize() anywhere except openPopover() before show()
// ❌ NEVER change sizingOptions away from []
// ❌ NEVER use sizingOptions = .preferredContentSize
// ❌ NEVER remove .frame(width: 420) from nav-state view factories
// ❌ NEVER add sizing calls to navigate()
// ❌ NEVER remove @MainActor from the AppDelegate class declaration.
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded or enrichGroupIfNeeded.
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var popoverIsOpen = false

    /// Canonical popover width. Must match .frame(width:) on every nav-state view.
    /// ❌ NEVER change without updating ALL view factories simultaneously.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let canonicalWidth: CGFloat = 420
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
        // ⚠️ sizingOptions = [] is mandatory.
        // .preferredContentSize causes re-anchor on every SwiftUI layout pass → left jump.
        // ❌ NEVER change to .preferredContentSize.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        controller.sizingOptions = []
        hostingController = controller

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ❌ NOTHING ELSE here. No sizing. No navigate(). Fires while shown → jump.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
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

    /// nonisolated: called from DispatchQueue.global — pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
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

    /// nonisolated: called from DispatchQueue.global — pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    nonisolated private func enrichGroupIfNeeded(_ group: ActionGroup) -> ActionGroup {
        guard group.jobs.isEmpty else { return group }
        let fetched = fetchActionGroups(for: group.repo)
        return fetched.first(where: { $0.id == group.id }) ?? group
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

    private func actionDetailView(group: ActionGroup) -> AnyView {
        savedNavState = .actionDetail(group)
        // ⚠️ .frame(width: canonicalWidth) is REQUIRED with sizingOptions=[].
        // Without it, SwiftUI has no width constraint and the view collapses → crash.
        // ❌ NEVER remove this .frame(width:) call.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
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
        ).frame(width: Self.canonicalWidth))
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
        ).frame(width: Self.canonicalWidth))
    }

    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
        ).frame(width: Self.canonicalWidth))
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
        ).frame(width: Self.canonicalWidth))
    }

    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            store: observable
        ).frame(width: Self.canonicalWidth))
    }

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
        ).frame(width: Self.canonicalWidth))
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

    /// Pure rootView swap. ZERO size changes. Forever.
    /// ❌ NEVER add contentSize or setFrameSize here.
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

    /// Two-phase open for true dynamic height without side-jump.
    ///
    /// WHY TWO PHASES:
    ///   Phase 1 (sync): Stage the correct view and reload observable data.
    ///     SwiftUI schedules a layout pass but has NOT run it yet.
    ///   Phase 2 (next runloop tick via DispatchQueue.main.async):
    ///     By this point SwiftUI has completed its layout pass.
    ///     layoutSubtreeIfNeeded() finalises the AppKit layer.
    ///     fittingSize now reflects the ACTUAL rendered content → dynamic height.
    ///     contentSize is set once, show() is called. Nothing touches sizing after.
    ///
    /// This is the standard solution for dynamic-height NSPopover described in:
    ///   - Just10/MEMORY.md (sizingOptions=[], measure before show)
    ///   - issue #377 architecture table
    ///   - status-bar-app-position-warning.md
    ///
    /// ❌ NEVER set contentSize or setFrameSize after show()
    /// ❌ NEVER collapse phases back into one synchronous block (race → stale height)
    /// ❌ NEVER move sizing into navigate() or onChange
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }

        // ── Phase 1 (sync): stage view and data ───────────────────────────────
        popoverIsOpen = true
        observable.reload()

        // Restore saved nav state so the correct view is staged for measurement.
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            hostingController.rootView = restored
        }

        // ── Phase 2 (next runloop tick): SwiftUI has now settled its layout ───
        // Capture what we need; avoid capturing self strongly in the closure.
        DispatchQueue.main.async { [weak self, weak button, weak popover, weak hostingController] in
            guard let self,
                  let button,
                  let popover,
                  let hostingController,
                  self.popoverIsOpen   // guard against rapid open/close
            else { return }

            // Force AppKit to sync with the now-settled SwiftUI layout.
            hostingController.view.layoutSubtreeIfNeeded()

            // Measure real content height and clamp to sane bounds.
            let rawHeight = hostingController.view.fittingSize.height
            let height = min(max(rawHeight > 0 ? rawHeight : 300, Self.minHeight), Self.maxHeight)
            let size = NSSize(width: Self.canonicalWidth, height: height)

            // Set size ONCE, BEFORE show(). Nothing touches sizing after this.
            hostingController.view.setFrameSize(size)
            popover.contentSize = size

            // Show. From this point on, sizing is frozen until next open.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
// swiftlint:enable type_body_length
