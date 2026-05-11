import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE: sizingOptions=[] + remeasurePopover() async after every navigate()
//
//   sizingOptions = []  ← CRITICAL. Prevents NSHostingController from auto-propagating
//   preferredContentSize to NSPopover. Any write to contentSize while shown causes
//   NSPopover to re-anchor → side-jump. [] is the ONLY safe value.
//   ❌ NEVER use sizingOptions = .preferredContentSize
//
//   DYNAMIC HEIGHT — how it works:
//   1. openPopover() measures fittingSize ONCE before show() (initial size)
//   2. navigate() swaps rootView then calls remeasurePopover() via 1 async hop
//   3. log views call onLogLoaded which remeasures via 2 async hops (content is async)
//   4. "Load more" calls onContentChanged which remeasures via 1 async hop
//   remeasurePopover() reads fittingSize.height at fixedWidth, writes contentSize
//   ONLY when popover is shown and height actually changed. Width is ALWAYS fixedWidth.
//
//   WHY WIDTH NEVER JUMPS:
//   Width is always Self.fixedWidth (480). fittingSize.width is NEVER used —
//   it is non-deterministic with maxWidth:.infinity. contentSize.width is always 480.
//   NSPopover only re-anchors when contentSize.width changes. Width never changes.
//
//   WHY DOUBLE ASYNC HOP FOR LOG VIEWS:
//   StepLogView loads log content asynchronously. On the first run-loop turn after
//   navigate(), fittingSize.height still reflects the loading spinner (small).
//   A second async hop gives SwiftUI time to commit the loaded content.
//   One hop is not enough — do NOT reduce to one hop for log views.
//
//   TIMER GUARD:
//   store.reload() and LocalRunnerStore.shared.refresh() are gated behind !popoverIsOpen.
//   store.reload() → @ObservedObject mutation → SwiftUI layout pass. With sizingOptions=[]
//   this does NOT reach NSPopover but wastes CPU and can flicker.
//   ❌ NEVER call store.reload() while popoverIsOpen == true.
//
//   SAVED NAV STATE — close→reopen restoration (ref #378):
//   savedNavState persists across close→reopen so the user lands back on the same view.
//   ❌ NEVER call mainView() from popoverDidClose — mainView() sets savedNavState = nil,
//      which races with openPopover() reading it, and the nav state is lost.
//   ✅ popoverDidClose resets hostingController.rootView directly (without mainView())
//      so savedNavState survives until openPopover() captures and clears it.
//   ✅ openPopover() captures savedNavState into a local var FIRST, then sets it to nil,
//      so the async-hop rootView reset in popoverDidClose cannot race with it.
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER use fittingSize.width — non-deterministic
// ❌ NEVER write contentSize while popover is not shown
// ❌ NEVER remove .frame(idealWidth: 480) from ANY view in the nav tree
// ❌ NEVER use a different idealWidth value in ANY view (must all be 480)
// ❌ NEVER call store.reload() while popoverIsOpen == true
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView loads async — fittingSize.height is spinner-height before load
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded
//    Called from DispatchQueue.global — pure network I/O, no @MainActor state
// ❌ NEVER call mainView() from popoverDidClose — races with savedNavState (ref #378)
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
    /// ❌ NEVER use fittingSize.width — use this constant for ALL width sizing calls.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let fixedWidth: CGFloat = 480
    private static let minHeight: CGFloat = 120
    private static let maxHeight: CGFloat = 680

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }
        let controller = NSHostingController(rootView: mainView())
        // ✅ sizingOptions = [] — CRITICAL. Prevents auto-propagation of
        // preferredContentSize to NSPopover while shown. See regression guard above.
        // ❌ NEVER remove or change to .preferredContentSize.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
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
            // ❌ NEVER call observable.reload() while popoverIsOpen == true.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        // ⚠️ FIX #378 — do NOT call mainView() here.
        // mainView() sets savedNavState = nil, which races with openPopover() reading
        // savedNavState to restore the previous nav state (e.g. Settings).
        // Instead, reset the hosting controller root view directly using mainView()'s
        // content but without the savedNavState = nil side-effect of calling mainView().
        // savedNavState is intentionally preserved here — openPopover() captures it
        // into a local var and then clears it atomically before any async work.
        // ❌ NEVER replace this with a call to mainView() — that causes the race.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.freshMainView()
        }
    }

    // MARK: - Remeasure

    /// Remeasures fittingSize.height and updates contentSize/frame if the popover is shown
    /// and the height has actually changed. Width is ALWAYS fixedWidth — never fittingSize.width.
    ///
    /// Called:
    ///   - navigate(): 1 async hop after rootView swap
    ///   - onLogLoaded: 2 async hops after async log content loads
    ///   - onContentChanged ("Load more"): 1 async hop after list expands
    ///
    /// ❌ NEVER call synchronously — fittingSize is not stable until the run-loop completes.
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
    /// ❌ NEVER call while popover is not shown — contentSize write while hidden causes
    ///    the next show() to re-anchor at the wrong size.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func remeasurePopover() {
        guard let popover, popover.isShown,
              let hostingController else { return }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        // Give SwiftUI full vertical room at the correct width so fittingSize is accurate.
        hostingController.view.setFrameSize(
            NSSize(width: Self.fixedWidth, height: screenHeight)
        )
        hostingController.view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let natural = hostingController.view.fittingSize.height
        guard natural > 0 else { return }
        let clamped = min(max(natural, Self.minHeight), Self.maxHeight)
        let newSize = NSSize(width: Self.fixedWidth, height: clamped)
        // Only write contentSize if height actually changed — avoids spurious re-anchors.
        guard abs(popover.contentSize.height - clamped) > 1 else { return }
        hostingController.view.setFrameSize(newSize)
        popover.contentSize = newSize
    }

    // MARK: - Navigation

    /// Swaps the hosting controller root view then remeasures the popover height
    /// via one async hop (gives SwiftUI one run-loop turn to commit the new layout).
    ///
    /// ❌ NEVER call remeasurePopover() synchronously here — fittingSize is stale
    ///    until the run-loop completes after rootView assignment.
    /// ❌ NEVER call this from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
        DispatchQueue.main.async { [weak self] in
            self?.remeasurePopover()
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

    /// Returns a fresh PopoverMainView wired with all callbacks.
    /// Does NOT touch savedNavState — callers that need to clear it must do so explicitly.
    ///
    /// ⚠️ FIX #378: This replaces the pattern of calling mainView() from popoverDidClose.
    /// mainView() sets savedNavState = nil as a side-effect, which races with openPopover()
    /// reading savedNavState. freshMainView() produces the same view without the side-effect.
    /// ✅ Call freshMainView() from popoverDidClose (no savedNavState mutation).
    /// ✅ Call mainView() only from openPopover() and navigate() paths where clearing
    ///    savedNavState is intentional.
    /// ❌ NEVER call mainView() from popoverDidClose.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func freshMainView() -> AnyView {
        AnyView(PopoverMainView(
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
            onContentChanged: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.remeasurePopover()
                }
            },
            isPopoverOpen: popoverIsOpen
        ))
    }

    private func mainView() -> AnyView {
        savedNavState = nil
        return freshMainView()
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
        // ⚠️ onLogLoaded uses TWO async hops — log content is async-loaded.
        // One hop is not enough: fittingSize still reflects the spinner on the first turn.
        // ❌ NEVER reduce to one hop. ❌ NEVER call remeasurePopover() synchronously.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            },
            onLogLoaded: { [weak self] in
                DispatchQueue.main.async {
                    DispatchQueue.main.async { [weak self] in
                        self?.remeasurePopover()
                    }
                }
            }
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
        // ⚠️ onLogLoaded uses TWO async hops — log content is async-loaded.
        // One hop is not enough: fittingSize still reflects the spinner on the first turn.
        // ❌ NEVER reduce to one hop. ❌ NEVER call remeasurePopover() synchronously.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            },
            onLogLoaded: { [weak self] in
                DispatchQueue.main.async {
                    DispatchQueue.main.async { [weak self] in
                        self?.remeasurePopover()
                    }
                }
            }
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

    // MARK: - Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover, measuring content height once before show().
    /// After show(), height is kept dynamic via remeasurePopover() called from navigate().
    ///
    /// ⚠️ FIX #378 — savedNavState capture pattern:
    /// savedNavState is captured into a local `pendingRestore` FIRST, then cleared to nil
    /// BEFORE any async work. This prevents the race where popoverDidClose's async hop
    /// (resetting hostingController.rootView via freshMainView) could overlap with a
    /// concurrent openPopover() call and find savedNavState already nil.
    ///
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
    /// ❌ NEVER remove CATransaction.flush() — needed to flush SwiftUI layout before fittingSize.
    /// ❌ NEVER call observable.reload() after show().
    /// ❌ NEVER read savedNavState after the point where pendingRestore is assigned —
    ///    by that point it is already nil and the value lives in pendingRestore.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }

        // ⚠️ FIX #378: Capture savedNavState BEFORE anything clears it, then nil it out
        // immediately. This is the only safe read point — popoverDidClose's async hop may
        // still be in flight (resetting hostingController.rootView), and mainView() called
        // anywhere below would also set savedNavState = nil.
        let pendingRestore = savedNavState
        savedNavState = nil

        popoverIsOpen = true
        observable.reload()

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        hostingController.view.setFrameSize(
            NSSize(width: Self.fixedWidth, height: screenHeight)
        )
        hostingController.view.layoutSubtreeIfNeeded()
        // ❌ NEVER remove CATransaction.flush() — without it fittingSize.height = 0.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        CATransaction.flush()

        let natural = hostingController.view.fittingSize.height
        let height = min(max(natural > 0 ? natural : Self.minHeight, Self.minHeight), Self.maxHeight)
        let finalSize = NSSize(width: Self.fixedWidth, height: height)
        hostingController.view.setFrameSize(finalSize)
        popover.contentSize = finalSize

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        if let pending = pendingRestore,
           let restored = validatedView(for: pending) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
