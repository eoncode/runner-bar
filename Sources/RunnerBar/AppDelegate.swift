import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE CORRECT ARCHITECTURE (zero-jump, zero-collapse):
//
//   sizingOptions = []  ← CRITICAL. Prevents NSHostingController from auto-propagating
//   preferredContentSize to NSPopover while it is shown. Any write to contentSize
//   while shown causes NSPopover to re-anchor → side-jump. [] is the ONLY safe value.
//   ❌ NEVER use sizingOptions = .preferredContentSize — every SwiftUI layout pass
//      (including live-poll updates, RunnerStore.onChange, timer ticks) pushes a new
//      preferredContentSize → contentSize write → re-anchor → side-jump.
//      Confirmed by Just10/MEMORY.md, #377, #375, #376.
//
//   HEIGHT MEASUREMENT (openPopover only, before show()):
//   1. Set hosting view frame to idealWidth × screenHeight (gives SwiftUI full room)
//   2. layoutSubtreeIfNeeded()  — flush AppKit layout
//   3. CATransaction.flush()    — flush SwiftUI render pipeline through ScrollView
//      WITHOUT this, fittingSize.height = 0 through a ScrollView because SwiftUI's
//      render pass hasn't completed. CATransaction.flush() forces it synchronously.
//   4. Read fittingSize.height  — now reflects actual content, clamped min/max
//   5. Set contentSize ONCE before show()
//   Height is correct at open. Does NOT live-update while shown — use ScrollView
//   internally for overflow. This is the pattern used by every comparable app.
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//
//   WHY WIDTH NEVER JUMPS:
//   Width is always Self.idealWidth (480). fittingSize.width is NEVER used
//   (non-deterministic with maxWidth:.infinity). contentSize.width is always 480.
//   NSPopover only re-anchors when contentSize changes. With sizingOptions = [],
//   contentSize is never touched after show(). Zero jumps.
//
//   WHY THE TIMER GUARD IS CRITICAL:
//   The 5s timer in PopoverMainView gates store.reload() behind !isPopoverOpen.
//   store.reload() mutates @ObservedObject → SwiftUI layout pass. With sizingOptions=[]
//   that layout pass does NOT reach NSPopover (no preferredContentSize propagation).
//   But LocalRunnerStore.shared.refresh() is also safe unconditionally because it
//   does NOT mutate the @ObservedObject store bound to this view.
//   ❌ NEVER call store.reload() while popoverIsOpen == true.
//   ❌ NEVER remove the isPopoverOpen guard from the timer.
//
//   OPEN SEQUENCE (correct order, do NOT reorder):
//   1. popoverIsOpen = true
//   2. observable.reload()           ← loads live data into @ObservedObject
//   3. Measure fittingSize (with CATransaction.flush()) at idealWidth
//   4. Set contentSize ONCE
//   5. show()                        ← popover appears at correct height, no jump
//   6. navigate(to: restored)        ← rootView swap AFTER show. Zero sizing.
//
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER manually set contentSize after show()
// ❌ NEVER use fittingSize.width
// ❌ NEVER add contentSize or setFrameSize to navigate()
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from ANY view in the nav tree
// ❌ NEVER use a different idealWidth value in ANY view (must all be 480)
// ❌ NEVER call store.reload() while popoverIsOpen == true
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView has maxHeight:.infinity — fittingSize.height is 0 before log loads
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
    /// ❌ NEVER use this for contentSize.height — height is measured via fittingSize.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let idealWidth: CGFloat = 480
    private static let minHeight: CGFloat = 120
    private static let maxHeight: CGFloat = 620

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
        let initialSize = NSSize(width: Self.idealWidth, height: 300)
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
            // reload() → @ObservedObject mutation → SwiftUI layout pass.
            // With sizingOptions=[] this does NOT reach NSPopover, but it is
            // still wasteful and can cause visible flicker.
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
    /// With sizingOptions=[], no preferredContentSize propagation occurs. Pure view swap.
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

    /// Opens the popover, measuring content height exactly once before show().
    ///
    /// Height measurement sequence (ref #375 #376 #377 Just10/MEMORY.md):
    ///   1. Reload live data into @ObservedObject
    ///   2. Set hosting view frame to idealWidth × screenHeight (full room for layout)
    ///   3. layoutSubtreeIfNeeded()  — flush AppKit layout pass
    ///   4. CATransaction.flush()    — flush SwiftUI render pipeline through ScrollView
    ///      CRITICAL: without this, fittingSize.height = 0 through a ScrollView because
    ///      SwiftUI's render pass hasn't completed synchronously.
    ///   5. Read fittingSize.height, clamp to [minHeight, maxHeight]
    ///   6. Set contentSize ONCE at idealWidth × clampedHeight
    ///   7. show() — popover appears at correct size, no re-anchor ever
    ///
    /// After show(), contentSize is NEVER written again (sizingOptions=[] enforces this).
    ///
    /// ❌ NEVER add contentSize writes after show().
    /// ❌ NEVER remove CATransaction.flush() — breaks height through ScrollView.
    /// ❌ NEVER remove layoutSubtreeIfNeeded() — needed before CATransaction.flush().
    /// ❌ NEVER use fittingSize.width — non-deterministic with maxWidth:.infinity.
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

        // Step 1: reload live data so fittingSize reflects current content.
        observable.reload()

        // Step 2: give the hosting view full vertical room at the correct width.
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let measureFrame = NSSize(width: Self.idealWidth, height: screenHeight)
        hostingController.view.setFrameSize(measureFrame)

        // Step 3: flush AppKit layout.
        hostingController.view.layoutSubtreeIfNeeded()

        // Step 4: flush SwiftUI render pipeline.
        // CRITICAL: ScrollView defers its layout pass. Without CATransaction.flush(),
        // fittingSize.height = 0 and the popover opens at minHeight.
        // ❌ NEVER remove this line.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        CATransaction.flush()

        // Step 5: read actual content height, clamped to safe range.
        let natural = hostingController.view.fittingSize.height
        let height = min(max(natural > 0 ? natural : Self.minHeight, Self.minHeight), Self.maxHeight)

        // Step 6: set contentSize ONCE. This is the ONLY write to contentSize after launch.
        let finalSize = NSSize(width: Self.idealWidth, height: height)
        hostingController.view.setFrameSize(finalSize)
        popover.contentSize = finalSize

        // Step 7: show.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        // Restore nav state (pure rootView swap — zero sizing).
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
