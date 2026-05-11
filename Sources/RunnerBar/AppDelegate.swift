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
//   only when height actually changed. Width is ALWAYS fixedWidth. Frame is ALWAYS
//   collapsed back to finalSize — never left at screenHeight after measurement.
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
//   POPOVEROPENSTATE ENVIRONMENT OBJECT (ref #377):
//   popoverOpenState is an ObservableObject injected into EVERY view via wrapEnv(_:).
//   InlineJobRowsView reads it as @EnvironmentObject to gate the "expand" button.
//   popoverOpenState.isOpen must always mirror popoverIsOpen — set both together.
//   ❌ NEVER remove this property.
//   ❌ NEVER remove .environmentObject(popoverOpenState) from wrapEnv().
//   ❌ NEVER pass isPopoverOpen as a plain Bool prop to InlineJobRowsView.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
//   BLANK VIEW BUG — why setFrameSize(finalSize) MUST precede the height-delta guard:
//   remeasurePopover() expands the hosting view to screenHeight so SwiftUI can report
//   its true fittingSize. After measuring, the frame MUST be collapsed back to finalSize
//   regardless of whether contentSize changes. If the height-delta guard fires first and
//   returns early, the hosting view stays at screenHeight while contentSize is e.g. 680pt —
//   NSHostingController renders blank white (content outside the popover window bounds).
//   ❌ NEVER move setFrameSize(finalSize) inside or after the height-delta guard.
//   ❌ NEVER return before setFrameSize(finalSize).
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

    // ⚠️ REGRESSION GUARD (ref #377):
    // Injected into every view via wrapEnv(). InlineJobRowsView reads it as
    // @EnvironmentObject to gate cap mutations while the popover is open.
    // isOpen must always mirror popoverIsOpen — set both together.
    // ❌ NEVER remove this property.
    // ❌ NEVER remove .environmentObject(popoverOpenState) from wrapEnv().
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Canonical popover width. Must match idealWidth in ALL views in the nav tree.
    /// ❌ NEVER change without updating idealWidth in PopoverMainView, SettingsView,
    ///    JobDetailView, ActionDetailView, AND StepLogView.
    /// ❌ NEVER use fittingSize.width — use this constant for ALL width sizing calls.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let fixedWidth: CGFloat = 480
    private static let minHeight: CGFloat = 120
    private static let maxHeight: CGFloat = 680

    // MARK: - Environment injection helper

    /// Wraps any view in AnyView and injects all required environment objects.
    ///
    /// ALL view factories MUST go through this helper so @EnvironmentObject
    /// consumers never crash with a missing object.
    ///
    /// ❌ NEVER bypass wrapEnv() and return AnyView(...) directly from a view factory.
    /// ❌ NEVER remove .environmentObject(popoverOpenState) from this method.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    /// ALLOWED UNDER ANY CIRCUMSTANCE.
    private func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(popoverOpenState))
    }

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
        // ⚠️ Mirror popoverIsOpen into popoverOpenState so @EnvironmentObject
        // consumers (InlineJobRowsView) see the correct live value.
        // ❌ NEVER remove. ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - Remeasure

    /// Remeasures fittingSize.height and updates contentSize/frame.
    /// Width is ALWAYS fixedWidth — never fittingSize.width.
    ///
    /// Sequence:
    ///   1. Expand hosting view frame to screenHeight (unconstrained room for fittingSize)
    ///   2. layoutSubtreeIfNeeded() + CATransaction.flush() (flush layout pipeline)
    ///   3. Read fittingSize.height, clamp to [minHeight, maxHeight]
    ///   4. ALWAYS setFrameSize(finalSize) — collapse frame back from screenHeight.
    ///      ❌ NEVER skip or defer this — hosting view left at screenHeight renders blank white.
    ///   5. Write popover.contentSize ONLY when height changed (avoids spurious re-anchors)
    ///
    /// ❌ NEVER call synchronously — fittingSize is not stable until run-loop completes.
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
    /// ❌ NEVER call while popover is not shown.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func remeasurePopover() {
        guard let popover, popover.isShown,
              let hostingController else { return }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        // Step 1: expand to full screen height so fittingSize is unconstrained.
        hostingController.view.setFrameSize(
            NSSize(width: Self.fixedWidth, height: screenHeight)
        )
        // Step 2: flush layout pipeline.
        hostingController.view.layoutSubtreeIfNeeded()
        // ❌ NEVER remove CATransaction.flush() — without it fittingSize.height = 0
        // for views that contain a ScrollView.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        CATransaction.flush()
        // Step 3: read and clamp.
        let natural = hostingController.view.fittingSize.height
        guard natural > 0 else {
            // Guard-out: restore frame to current contentSize — never leave at screenHeight.
            // ❌ NEVER remove this setFrameSize call.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            hostingController.view.setFrameSize(
                NSSize(width: Self.fixedWidth, height: popover.contentSize.height)
            )
            return
        }
        let clamped = min(max(natural, Self.minHeight), Self.maxHeight)
        let finalSize = NSSize(width: Self.fixedWidth, height: clamped)
        // Step 4: ALWAYS collapse frame back to finalSize.
        // ❌ NEVER move this after the height-delta guard below.
        // ❌ NEVER remove this call — blank white views result if the frame stays at screenHeight.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        hostingController.view.setFrameSize(finalSize)
        // Step 5: only write contentSize if height actually changed.
        // Writing contentSize unconditionally triggers NSPopover re-anchor on every
        // async hop → side-jump. Only write when height truly changed.
        guard abs(popover.contentSize.height - clamped) > 1 else { return }
        popover.contentSize = finalSize
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

    private func mainView() -> AnyView {
        savedNavState = nil
        return wrapEnv(PopoverMainView(
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

    private func actionDetailView(group: ActionGroup) -> AnyView {
        savedNavState = .actionDetail(group)
        return wrapEnv(ActionDetailView(
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
        return wrapEnv(JobDetailView(
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
        // ❌ NEVER reduce to one hop. ❌ NEVER call remeasurePopover() synchronously.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        return wrapEnv(StepLogView(
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
        return wrapEnv(JobDetailView(
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
        return wrapEnv(SettingsView(
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
        // ❌ NEVER reduce to one hop. ❌ NEVER call remeasurePopover() synchronously.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        return wrapEnv(StepLogView(
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
    ///
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
    /// ❌ NEVER remove CATransaction.flush() — needed to flush SwiftUI layout before fittingSize.
    /// ❌ NEVER call observable.reload() after show().
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }

        popoverIsOpen = true
        // ⚠️ Set isOpen BEFORE show() so InlineJobRowsView sees isOpen=true on first render.
        // ❌ NEVER set popoverIsOpen without also setting popoverOpenState.isOpen.
        // ❌ NEVER move this line after show().
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = true
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

        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
