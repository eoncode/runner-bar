import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #377)
//
// ARCHITECTURE: Architecture 2b (AppKit-driven, SwiftUI-reported height)
// Confirmed correct by issue #377, status-bar-app-position-warning.md
//
// HEIGHT MECHANISM:
//   PopoverMainView reports its rendered height via HeightPreferenceKey
//   (a SwiftUI PreferenceKey backed by a GeometryReader in .background).
//   AppDelegate reads this in .onPreferenceChange and stores it in measuredHeight.
//   openPopover() Phase 3 reads measuredHeight directly — fittingSize is NEVER used.
//
//   WHY NOT fittingSize:
//   NSHostingController.view.fittingSize with sizingOptions=[] is cached and stale.
//   invalidateIntrinsicContentSize() + layoutSubtreeIfNeeded() does NOT reliably
//   bust this cache. Every attempt to use fittingSize has produced stale/fixed height.
//   ❌ NEVER switch back to fittingSize.
//   ❌ NEVER remove HeightPreferenceKey or .onPreferenceChange from the view.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// PHASE TIMING (ref #377):
//   sizingOptions=[] means the hosting view starts with a ZERO frame.
//   GeometryReader in PopoverMainView.body sees zero width → reports zero height.
//   Fix (Nuclear, 3-phase via nested DispatchQueue.main.async):
//     Phase 1 (sync):  stage view + reload data.
//     Phase 2 (hop 1): prime the hosting view to canonicalWidth×minHeight
//       so SwiftUI lays out against a real width. This triggers HeightPreferenceKey.
//     Phase 3 (hop 2 + hop 3): read measuredHeight (now valid), set final
//       contentSize, show().
//   ❌ NEVER collapse to a single async hop — stale height.
//   ❌ NEVER remove the priming step — without it GeometryReader reads zero width.
//   ❌ NEVER use Task/await for this — guard let on non-optionals causes compile error.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// Rules (ALL must hold simultaneously):
//   sizingOptions = []        — NEVER .preferredContentSize.
//                               .preferredContentSize auto-pushes on every SwiftUI
//                               layout pass while shown → re-anchor → left jump.
//   openPopover()             — the ONE place contentSize is set.
//                               Three-phase open (nested DispatchQueue.main.async):
//                                 Phase 1 (sync): stage view + reload data.
//                                 Phase 2 (hop 1): prime to canonicalWidth,
//                                   let SwiftUI re-layout and fire HeightPreferenceKey.
//                                 Phase 3 (hop 2 then hop 3): read measuredHeight,
//                                   clamp → setFrameSize → contentSize → show().
//   navigate()                — rootView swap ONLY. ZERO size changes. Forever.
//   .frame(width: 420)        — MUST wrap every non-main nav-state view.
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
// ❌ NEVER remove HeightPreferenceKey wiring from PopoverMainView.
// ❌ NEVER remove .onPreferenceChange(HeightPreferenceKey.self) from wrapWithHeightCapture.
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

    /// Last height reported by HeightPreferenceKey from PopoverMainView.
    /// Updated on every SwiftUI render. Used by openPopover() instead of fittingSize.
    /// ❌ NEVER read this before Phase 3 of openPopover() — it reflects the previous render.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private var measuredHeight: CGFloat = 300

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

        let rootView = wrapWithHeightCapture(mainView())
        let controller = NSHostingController(rootView: rootView)
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
            let rootView = self.wrapWithHeightCapture(self.mainView())
            self.hostingController?.rootView = rootView
        }
    }

    // MARK: - Height capture wrapper

    /// Wraps any view with HeightPreferenceKey capture so AppDelegate always has
    /// an up-to-date measuredHeight for the current content.
    /// ❌ NEVER remove this wrapper — it is the sole source of truth for popover height.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func wrapWithHeightCapture(_ view: AnyView) -> AnyView {
        AnyView(
            view
                .onPreferenceChange(HeightPreferenceKey.self) { [weak self] height in
                    guard let self, height > 0 else { return }
                    self.measuredHeight = height
                }
        )
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
        hostingController?.rootView = wrapWithHeightCapture(view)
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

    /// Three-phase open using SwiftUI-reported height (HeightPreferenceKey).
    /// Uses nested DispatchQueue.main.async (NOT Task/await) to avoid
    /// guard-let-on-non-optional compile errors from Swift's weak capture rules.
    ///
    /// ROOT CAUSE OF FIXED HEIGHT:
    ///   sizingOptions=[] means the hosting view starts with a ZERO frame.
    ///   GeometryReader in PopoverMainView.body fires with zero width → zero height.
    ///   measuredHeight never updates above its default (300) → always 300px popover.
    ///
    /// THE FIX (3 phases, nested async hops):
    ///   Phase 1 (sync): Stage view + reload data.
    ///   Phase 2 (hop 1): Prime hosting view to canonicalWidth × minHeight.
    ///     SwiftUI now lays out against a real 420pt width. HeightPreferenceKey fires
    ///     with the true content height and updates measuredHeight.
    ///   Phase 3 (hop 2 then hop 3): Read measuredHeight (now valid from Phase 2),
    ///     clamp → setFrameSize → contentSize → show().
    ///
    /// ❌ NEVER use fittingSize — reverts to stale/cached height
    /// ❌ NEVER set contentSize or setFrameSize after show()
    /// ❌ NEVER remove the priming step in Phase 2 — GeometryReader reads zero without it
    /// ❌ NEVER collapse to fewer than 3 async hops — wrong height / side-jump regression
    /// ❌ NEVER use Task/await here — guard let on locals causes compile error on Swift 5
    /// ❌ NEVER move sizing into navigate() or onChange
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hc = hostingController
        else { return }

        // ── Phase 1 (sync): stage view and data ──────────────────────────────
        popoverIsOpen = true
        observable.reload()

        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            hc.rootView = wrapWithHeightCapture(restored)
        }

        // ── Phase 2 (hop 1): prime hosting view to real width ──────────────
        // sizingOptions=[] → hosting view frame is zero until we set it.
        // Without a real width, SwiftUI wraps to zero → GeometryReader → zero height.
        // Set canonicalWidth × minHeight so SwiftUI has a real container to measure.
        // HeightPreferenceKey will fire after this layout pass with the true height.
        // ❌ NEVER remove this hop or this priming block.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popoverIsOpen else { return }
            hc.view.setFrameSize(NSSize(width: Self.canonicalWidth, height: Self.minHeight))

            // ── Phase 3a (hop 2): let SwiftUI complete layout + fire HeightPreferenceKey ──
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popoverIsOpen else { return }

                // ── Phase 3b (hop 3): HeightPreferenceKey callback has now run ──────
                // measuredHeight now reflects the actual SwiftUI content height.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.popoverIsOpen else { return }

                    let rawHeight = self.measuredHeight
                    let height = min(
                        max(rawHeight > 0 ? rawHeight : 300, Self.minHeight),
                        Self.maxHeight
                    )
                    let size = NSSize(width: Self.canonicalWidth, height: height)

                    // Set final size ONCE, BEFORE show(). Nothing touches sizing after this.
                    hc.view.setFrameSize(size)
                    popover.contentSize = size

                    // Show. Sizing is frozen from this point until next open.
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
                    popover.contentViewController?.view.window?.makeKey()
                }
            }
        }
    }
}
// swiftlint:enable type_body_length
