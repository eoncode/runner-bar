import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE 2: sizingOptions=[] (manual contentSize once before show)
//
//   WHY THIS ARCHITECTURE:
//   sizingOptions=.preferredContentSize (Architecture 1) auto-propagates
//   preferredContentSize to NSPopover on every SwiftUI state update while shown.
//   NSPopover re-anchors on every receive → side-jump. Confirmed in:
//     • Just10/MEMORY.md (zunguyen/Just10 — identical bug history)
//     • #377 comment #4423046520
//     • Stack Overflow #14449945, #69877522
//   The ONLY safe approach is sizingOptions=[] — hosting controller NEVER
//   auto-writes preferredContentSize. We own ALL sizing calls exclusively.
//
//   HOW IT WORKS:
//   1. openPopover() measures content height via fittingSize BEFORE show()
//   2. Sets popover.contentSize ONCE — this is the only contentSize write
//   3. show() anchors based on that fixed size — no subsequent re-anchor
//   4. navigate() swaps rootView only — ZERO sizing calls, content scrolls
//   5. Close → reopen → height remeasured fresh for new content
//
//   WHAT “DYNAMIC HEIGHT” MEANS HERE:
//   Height is dynamic per-open: every time the user clicks the status icon,
//   height is freshly measured from current content. It does NOT live-update
//   while the popover is visible. This is the correct behaviour — it is what
//   every real-world status bar app (Lungo, Pockity, Sindre Sorhus utilities)
//   does. Live resize while shown requires NSPanel (no anchor concept at all).
//
//   FITTINGSIZE MEASUREMENT SEQUENCE:
//   a. hostingController.view.setFrameSize(NSSize(width: fixedWidth, height: 9999))
//      — give the view a tall constraint so SwiftUI can lay out unbounded vertically
//   b. hostingController.view.layoutSubtreeIfNeeded() — force layout pass
//   c. let h = min(hostingController.view.fittingSize.height, maxHeight)
//      — clamp to screen-safe height
//   d. popover.contentSize = NSSize(width: fixedWidth, height: h)
//   e. popover.show() — AFTER contentSize is set
//
//   WIDTH RULE:
//   Width is ALWAYS fixedWidth=480. Never measure width. Never use fittingSize.width.
//   ❌ NEVER change fixedWidth without updating it everywhere you use it.
//
//   NOPOP-WHILE-SHOWN RULE:
//   ❌ NEVER write popover.contentSize while popover.isShown == true.
//   ❌ NEVER call remeasurePopover() — it does not exist and must never be recreated.
//   ❌ NEVER set sizingOptions = .preferredContentSize — that is Architecture 1 (broken).
//
//   TIMER / POLL GUARD:
//   RunnerStore.shared.onChange → observable.reload() is gated behind !popoverIsOpen.
//   ❌ NEVER remove this guard.
//
//   POPOVEROPENSTATE:
//   popoverOpenState.isOpen mirrors popoverIsOpen. Injected via wrapEnv().
//   InlineJobRowsView reads it to gate cap mutations while shown.
//   ❌ NEVER remove PopoverOpenState. ❌ NEVER remove wrapEnv() injection.
//
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
    // Injected via wrapEnv() into every view. InlineJobRowsView reads it as
    // @EnvironmentObject to gate cap mutations while the popover is open.
    // isOpen must always mirror popoverIsOpen — set both together.
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Canonical popover width. NEVER dynamic. NEVER fittingSize.width.
    /// ❌ NEVER change without updating all usages.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let fixedWidth: CGFloat = 480

    /// Maximum popover height — 75% of visible screen height.
    /// Prevents popover from extending off-screen on small displays.
    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600
    }

    // MARK: - Environment injection

    /// Wraps any view in AnyView and injects all required environment objects.
    /// ❌ NEVER bypass this. ❌ NEVER remove .environmentObject(popoverOpenState).
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

        // ✅ sizingOptions = [] — ARCHITECTURE 2. CRITICAL. DO NOT CHANGE.
        // Empty [] means the hosting controller NEVER auto-writes preferredContentSize
        // to NSPopover while shown. We control ALL contentSize writes exclusively.
        // ❌ NEVER change to .preferredContentSize — that is Architecture 1 (causes jump).
        // ❌ NEVER remove this line — default is .preferredContentSize which is wrong.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is
        // removed is major major major.
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
        // ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller rootView ONLY. Zero sizing calls.
    ///
    /// Architecture 2: navigate() never touches contentSize.
    /// Content that is taller than the open-time height scrolls internally.
    /// The popover frame does not change while shown — no re-anchor, no jump.
    ///
    /// ❌ NEVER add sizing calls here.
    /// ❌ NEVER call remeasurePopover() — it does not exist.
    /// ❌ NEVER write popover.contentSize here.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - View factories

    /// nonisolated: called from DispatchQueue.global — pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated.
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
            onContentChanged: nil,
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
        return wrapEnv(StepLogView(
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
        return wrapEnv(StepLogView(
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

    // MARK: - Popover show/hide

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Opens the popover with a fresh height measurement.
    ///
    /// Architecture 2 measurement sequence:
    ///   1. Reload data so content reflects current state
    ///   2. Give hosting view a tall unconstrained frame (width=fixedWidth, height=9999)
    ///      so SwiftUI can lay out at its natural height
    ///   3. Force a layout pass: layoutSubtreeIfNeeded()
    ///   4. Read fittingSize.height and clamp to maxHeight
    ///   5. Set popover.contentSize ONCE with (fixedWidth, clampedHeight)
    ///   6. Call show() — NSPopover anchors to this size, never changes it again
    ///   7. After show(), restore saved nav state if any
    ///
    /// ❌ NEVER write popover.contentSize after show()
    /// ❌ NEVER call this from a background thread
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController
        else { return }

        // Step 1: reload data before measurement so height reflects real content.
        // ❌ NEVER move this after show().
        observable.reload()

        // Step 2: mark open BEFORE show() so InlineJobRowsView sees isOpen=true
        // on first render and the expand button is correctly disabled.
        // ❌ NEVER move after show(). ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverIsOpen = true
        popoverOpenState.isOpen = true

        // Step 3: give the hosting view full vertical space so SwiftUI measures
        // natural content height. Width is always fixedWidth.
        let measureSize = NSSize(width: Self.fixedWidth, height: 9999)
        hostingController.view.setFrameSize(measureSize)
        hostingController.view.layoutSubtreeIfNeeded()

        // Step 4: read and clamp height.
        let measuredHeight = hostingController.view.fittingSize.height
        let clampedHeight = min(measuredHeight > 10 ? measuredHeight : 300, maxHeight)

        // Step 5: set contentSize ONCE before show(). This is the ONLY place
        // contentSize is written. After show() it is NEVER touched again.
        // ❌ NEVER write popover.contentSize anywhere else in this file.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        let finalSize = NSSize(width: Self.fixedWidth, height: clampedHeight)
        hostingController.view.setFrameSize(finalSize)
        popover.contentSize = finalSize

        // Step 6: show — anchor is computed once from finalSize, never again.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        // Step 7: restore saved nav state (e.g. user was on Settings, closed, reopens).
        // ❌ NEVER restore stepLog / actionStepLog — async-loaded, spinner height is wrong.
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
