import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE 1: sizingOptions=.preferredContentSize (SwiftUI-driven dynamic height)
//
//   WHY THIS ARCHITECTURE:
//   Any write to popover.contentSize while popover is shown causes NSPopover to
//   fully re-anchor from scratch → side-jump. The previous remeasurePopover()
//   approach wrote contentSize on every navigate() → jump on every navigation.
//   Architecture 1 avoids ALL contentSize writes while shown by letting SwiftUI
//   drive height automatically through preferredContentSize propagation.
//
//   HOW IT WORKS:
//   sizingOptions = .preferredContentSize → NSHostingController reads SwiftUI's
//   ideal size and auto-propagates to NSPopover. No AppKit writes needed while shown.
//
//   WIDTH STABILITY (prevents left-jump):
//   Every view in the nav tree MUST have .frame(idealWidth: fixedWidth) on its root.
//   This pins preferredContentSize.width = fixedWidth regardless of nav state.
//   NSPopover only re-anchors when contentSize.width changes. Width never changes.
//   ❌ NEVER change idealWidth without updating ALL views AND fixedWidth constant.
//   ❌ NEVER use .frame(width: X) instead of .frame(idealWidth: X) — NOT equivalent.
//   ❌ NEVER remove .frame(idealWidth: fixedWidth) from any view in the nav tree.
//
//   SETTINGS VIEW SPECIAL CASE:
//   SettingsView has a ScrollView that reports unbounded idealHeight. Without capping,
//   preferredContentSize.height spikes to full content height on navigate → NSPopover
//   repositions to stay on screen → side-jump. Fix: SettingsView root frame gets
//   .frame(idealWidth: fixedWidth, idealHeight: cappedHeight). The inner ScrollView
//   scrolls within cappedHeight. All other views: idealWidth only, no idealHeight.
//
//   SYSTEMSTATS TIMER GUARD (critical — was root cause of side jumping):
//   SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//   → preferredContentSize update → NSPopover re-anchor → side jump every 2 s.
//   Fix: systemStats.stop() must fire BEFORE show() on FIRST render.
//   PopoverMainView reads PopoverOpenState via @EnvironmentObject (live, never stale).
//   PopoverOpenState.isOpen is set to true BEFORE show() in openPopover().
//   ❌ NEVER pass isPopoverOpen as a frozen Bool prop to PopoverMainView.
//   ❌ NEVER read isPopoverOpen from a prop that was captured before openPopover().
//   ✅ Always read it from the live @EnvironmentObject PopoverOpenState.
//
//   TIMER / POLL GUARD:
//   RunnerStore.shared.onChange updates observable.reload() — gated behind !popoverIsOpen
//   to avoid @ObservedObject mutations while shown (wastes CPU, can flicker).
//   With sizingOptions=.preferredContentSize, SwiftUI content changes DO re-report
//   preferredContentSize — this is fine for height but MUST NOT change width.
//   Width is always pinned by idealWidth. ❌ NEVER remove the !popoverIsOpen guard.
//
//   POPOVEROPENSTATE ENVIRONMENT OBJECT (ref #377):
//   popoverOpenState is an ObservableObject injected into every view via wrapEnv(_:).
//   InlineJobRowsView reads it as @EnvironmentObject to gate the "expand" button.
//   PopoverMainView reads it as @EnvironmentObject to gate systemStats (not a Bool prop).
//   popoverOpenState.isOpen must always mirror popoverIsOpen — set both together.
//   ❌ NEVER remove this property.
//   ❌ NEVER remove .environmentObject(popoverOpenState) from wrapEnv().
//   ❌ NEVER pass isPopoverOpen as a plain Bool prop to PopoverMainView or InlineJobRowsView.
//
// ❌ NEVER use sizingOptions = [] — requires manual contentSize writes → jump
// ❌ NEVER call remeasurePopover() — deleted, was the source of every jump
// ❌ NEVER write popover.contentSize while popover is shown
// ❌ NEVER use fittingSize.width — non-deterministic
// ❌ NEVER remove .frame(idealWidth: 480) from ANY view in the nav tree
// ❌ NEVER use a different idealWidth value in ANY view (must all be 480)
// ❌ NEVER call store.reload() while popoverIsOpen == true
// ❌ NEVER restore stepLog or actionStepLog via savedNavState
//    StepLogView loads async — height is spinner-height before load
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
    // PopoverMainView reads it as @EnvironmentObject to gate systemStats.
    // isOpen must always mirror popoverIsOpen — set both together.
    // ❌ NEVER remove this property.
    // ❌ NEVER remove .environmentObject(popoverOpenState) from wrapEnv().
    // ❌ NEVER pass isPopoverOpen as a frozen Bool prop to PopoverMainView.
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
        // ✅ sizingOptions = .preferredContentSize — CRITICAL for Architecture 1.
        // NSHostingController reads SwiftUI ideal size and propagates automatically
        // to NSPopover. Height is dynamic, width is pinned via idealWidth on every view.
        // ❌ NEVER change to [] — requires manual contentSize writes → jump.
        // ❌ NEVER remove this line.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        controller.sizingOptions = .preferredContentSize
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
        // consumers (InlineJobRowsView, PopoverMainView systemStats gate) see
        // the correct live value.
        // ❌ NEVER remove. ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller root view.
    /// Architecture 1: rootView swap is all that's needed — SwiftUI re-reports
    /// preferredContentSize automatically. No manual sizing calls.
    ///
    /// ❌ NEVER call remeasurePopover() here — it's been deleted.
    /// ❌ NEVER write popover.contentSize here or anywhere while popover is shown.
    /// ❌ NEVER call this from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
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
        // ⚠️ REGRESSION GUARD: Do NOT pass isPopoverOpen as a Bool prop here.
        // PopoverMainView reads PopoverOpenState via @EnvironmentObject (live, never stale).
        // Passing a frozen Bool snapshot here was the root cause of the side-jump bug:
        // systemStats.stop() fired AFTER show() instead of BEFORE.
        // ❌ NEVER add isPopoverOpen: Bool prop back to PopoverMainView constructor.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
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
            onContentChanged: nil
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

    /// Opens the popover.
    /// Architecture 1: contentSize is set ONCE here before show().
    /// After show(), sizingOptions=.preferredContentSize takes over —
    /// NSHostingController propagates SwiftUI ideal size automatically.
    ///
    /// SYSTEMSTATS GATE ORDER (critical — was root cause of side jumping):
    /// popoverOpenState.isOpen = true is set BEFORE show().
    /// PopoverMainView reads PopoverOpenState via @EnvironmentObject — live, not a
    /// frozen Bool snapshot. This means systemStats.stop() fires on the FIRST SwiftUI
    /// render triggered by show(), before the 2s timer can fire.
    /// ❌ NEVER move popoverOpenState.isOpen = true to after show().
    /// ❌ NEVER pass isPopoverOpen as a Bool prop to PopoverMainView.
    ///
    /// ❌ NEVER write popover.contentSize after show() — triggers re-anchor → jump.
    /// ❌ NEVER use fittingSize.width — always Self.fixedWidth.
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
        // ⚠️ Set isOpen BEFORE show() so PopoverMainView sees isOpen=true on FIRST render.
        // This ensures systemStats.stop() fires synchronously before the 2s timer can
        // trigger a SwiftUI re-render → preferredContentSize update → side jump.
        // ❌ NEVER set popoverIsOpen without also setting popoverOpenState.isOpen.
        // ❌ NEVER move this line after show().
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = true
        observable.reload()

        // Set a reasonable initial contentSize before show().
        // After show(), sizingOptions=.preferredContentSize drives height automatically.
        // Width is always fixedWidth — never dynamic.
        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        hostingController.view.setFrameSize(initialSize)
        popover.contentSize = initialSize

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}
// swiftlint:enable type_body_length
