import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// THE ONLY CORRECT ARCHITECTURE (proven by main branch SHA e6bb42e, zero-regression):
//
//   navigate() = pure rootView swap. ZERO sizing. ZERO contentSize writes. EVER.
//   openPopover() = the ONE site where contentSize is set, BEFORE show().
//                   Reads fittingSize.HEIGHT ONLY from mainView() with live content.
//                   WIDTH is ALWAYS Self.idealWidth — NEVER fittingSize.width.
//                   Safe because popover.isShown == false at that point.
//
//   CRITICAL: controller.sizingOptions = [] MUST be set.
//   Default .preferredContentSize auto-propagates contentSize on every SwiftUI
//   layout pass (poll timer, onChange, @State ticks) → each write while shown
//   = NSPopover re-anchor = side-jump. sizingOptions=[] silences that.
//   Dynamic height is preserved: fittingSize.height is read fresh every open from
//   mainView() with live content, so height varies with content count.
//
//   WHY fittingSize.width IS BANNED:
//   When maxWidth:.infinity is in the SwiftUI tree, fittingSize.width is
//   non-deterministic — it can return 0, idealWidth, screen width, or anything
//   in between depending on the layout pass. Using it as contentSize.width means
//   contentSize.width varies between opens → NSPopover re-anchors → side-jump.
//   The fix is to ALWAYS use Self.idealWidth for width. No exceptions.
//
//   HOW DYNAMIC HEIGHT WORKS (no empty space, no clipping):
//   1. Set hc.view frame to idealWidth × screenHeight (gives SwiftUI enough room)
//   2. hc.view.layoutSubtreeIfNeeded() — force one layout pass at that width
//   3. Read hc.view.fittingSize.height — this is now the natural content height
//   4. Clamp to [minHeight, maxHeight]
//   5. Set hc.view.setFrameSize(idealWidth × clampedHeight)
//   6. popover.contentSize = that size
//   7. show()
//   Result: popover height exactly fits content. Width never changes. No jump.
//
//   CRITICAL: store.reload() MUST NOT be called while popoverIsOpen == true.
//   reload() while shown → SwiftUI layout pass → if sizingOptions != [] → side-jump.
//   PopoverMainView receives isPopoverOpen and gates reload() behind !isPopoverOpen.
//
//   CRITICAL: DO NOT add @MainActor to AppDelegate class declaration.
//   main.swift instantiates AppDelegate synchronously outside any actor context.
//   On Swift 6 strict concurrency (Xcode 26+), a @MainActor class init() called
//   from a nonisolated context is a compile error. Keep class nonisolated.
//   nonisolated enrichStepsIfNeeded is safe — it does pure network I/O only.
//
// OPEN SEQUENCE (do NOT reorder):
//   1. popoverIsOpen = true
//   2. observable.reload()          ← loads live data into mainView()
//   3. hc.view frame → idealWidth × screenHeight (measurement frame)
//   4. layoutSubtreeIfNeeded()      ← force layout at correct width
//   5. fittingSize.height           ← read AFTER layout. Height only. Never width.
//   6. setFrameSize + contentSize   ← safe: popover.isShown == false
//   7. show()
//   8. navigate(to: restored)       ← rootView swap AFTER show. Zero sizing. Safe.
//
// ❌ NEVER add @MainActor to AppDelegate class — breaks main.swift on Swift 6
// ❌ NEVER set sizingOptions = .preferredContentSize
// ❌ NEVER remove sizingOptions = []
// ❌ NEVER use fittingSize.width — ALWAYS use Self.idealWidth for width
//    fittingSize.width is non-deterministic when maxWidth:.infinity is in tree
// ❌ NEVER read fittingSize from a restored/Settings/Detail view in openPopover()
//    Previous commits did this: measured Settings height, locked contentSize to it,
//    then showed mainView → wrong height every other open.
// ❌ NEVER add contentSize or setFrameSize to navigate()
// ❌ NEVER wire onLogLoaded to any contentSize write
// ❌ NEVER add objectWillChange.send() in reload()
// ❌ NEVER remove .frame(idealWidth: 480) from PopoverMainView
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView: maxHeight:.infinity → fittingSize = 0 before log loads
// ❌ NEVER pass isPopoverOpen: false to mainView() when popover is shown
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

    /// Canonical popover width. ALL sizing uses this constant. NEVER fittingSize.width.
    /// ❌ NEVER change without updating idealWidth in PopoverMainView, SettingsView,
    ///    JobDetailView, ActionDetailView, AND StepLogView.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let idealWidth: CGFloat = 480
    private static let maxHeight:  CGFloat = 620
    private static let minHeight:  CGFloat = 120

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePopover)
            button.target = self
        }
        let controller = NSHostingController(rootView: mainView())
        // ❌ CRITICAL — DO NOT REMOVE THIS LINE. EVER.
        // Prevents NSHostingController from auto-propagating preferredContentSize
        // to the popover on every SwiftUI layout pass. Without this line every
        // store.reload(), timer tick, or @State change while the popover is shown
        // triggers a contentSize write → NSPopover re-anchor → side-jump.
        // Confirmed root cause: issue #377, main branch SHA e6bb42e.
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
            // ❌ NEVER touch contentSize / setFrameSize here — fires while popover
            // is shown → re-anchor → side-jump (Regression A).
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !self.popoverIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

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

    /// Swaps the hosting controller's root view. ZERO size changes. Forever.
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

    /// Opens the popover. The ONE safe site for sizing.
    ///
    /// WIDTH: always Self.idealWidth. Never fittingSize.width.
    ///   fittingSize.width is non-deterministic when maxWidth:.infinity is in tree.
    ///   Any variation in contentSize.width → NSPopover re-anchor → side-jump.
    ///
    /// HEIGHT: fittingSize.height, clamped to [minHeight, maxHeight].
    ///   Measured at idealWidth so text wrapping is computed at the correct width.
    ///   Measured BEFORE show() so popover.isShown == false — safe to write contentSize.
    ///
    /// ❌ NEVER use fittingSize.width for anything.
    /// ❌ NEVER read fittingSize from Settings or a detail view here.
    ///    Previous commits did this and broke height on every other open.
    /// ❌ NEVER call setFrameSize or set contentSize after show().
    /// ❌ NEVER add sizingOptions = .preferredContentSize — kills the fix.
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
        observable.reload()

        // Step 1: ensure the hosting view is showing mainView with live data.
        // navigate() to mainView was already called by popoverDidClose() or this is first open.
        // Do NOT call mainView() again here — it resets savedNavState prematurely.

        // Step 2: measure natural content height at the canonical width.
        // Set frame to idealWidth × tall screen so SwiftUI lays out at full height.
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let measureFrame = NSSize(width: Self.idealWidth, height: screenHeight)
        hostingController.view.setFrameSize(measureFrame)
        hostingController.view.layoutSubtreeIfNeeded()

        // Step 3: read height. NEVER read width.
        let naturalHeight = hostingController.view.fittingSize.height
        let height = min(max(naturalHeight > 0 ? naturalHeight : 300, Self.minHeight), Self.maxHeight)

        // Step 4: snap to final size — width is ALWAYS idealWidth.
        let finalSize = NSSize(width: Self.idealWidth, height: height)
        hostingController.view.setFrameSize(finalSize)
        popover.contentSize = finalSize

        // Step 5: show — popover anchors once to the button. contentSize never changes again.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        // Step 6: restore nav state if needed — pure rootView swap, zero sizing.
        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
