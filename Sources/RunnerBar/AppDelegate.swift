import AppKit
import SwiftUI

// swiftlint:disable type_body_length

// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE 3: sizingOptions=[] + GeometryReader/PreferenceKey dynamic height
//
// WHY:
// Architecture 1 (sizingOptions=.preferredContentSize):
//   NSPopover re-anchors on every SwiftUI state update → side-jump every 2s.
// Architecture 2 (fittingSize before show()):
//   RunnerStoreObservable.reload() is async — data not yet available at
//   measurement time → fittingSize always returns ~44pt → 300pt fallback.
// Architecture 3 (this commit):
//   Render content first. GeometryReader measures actual height after first
//   layout pass. PreferenceKey propagates height up. onHeightReady callback
//   calls popover.setContentSize() ONCE. animates=false = invisible resize.
//
// SEQUENCE:
// 1. openPopover():
//    a. observable.reload()              — sync snapshot; async data arrives later
//    b. popoverIsOpen = true
//       popoverOpenState.isOpen = true   — views see live open state immediately
//    c. popoverOpenState.heightReported = false  — arm the one-shot callback
//    d. popoverOpenState.onHeightReady = { [weak self, weak popover] h in
//           let clamped = min(h, self.maxHeight)
//           popover?.setContentSize(NSSize(width: Self.fixedWidth, height: clamped))
//       }                                — callback fires ONCE after first render
//    e. popover.contentSize = initial safe size (fixedWidth × 300)
//    f. popover.show()                   — opens at safe size, no anchor jump
//    g. SwiftUI renders content with real data
//    h. GeometryReader fires PreferenceKey with real height
//    i. onPreferenceChange → onHeightReady → setContentSize(real height)
//       animates=false → user sees correct height, never sees the initial 300pt
// 2. navigate(): rootView swap only — ZERO sizing calls.
// 3. popoverDidClose(): reset isOpen, heightReported, onHeightReady.
//
// WIDTH RULE:
// Width is ALWAYS fixedWidth=480. Never measure width dynamically.
// ❌ NEVER change fixedWidth without updating all usages.
//
// NO-RESIZE-WHILE-SHOWN RULE:
// setContentSize is called by onHeightReady ONCE immediately after first render.
// After heightReported=true, no further setContentSize calls occur.
// ❌ NEVER write popover.contentSize or call setContentSize while popover.isShown
//    except via the onHeightReady one-shot callback.
// ❌ NEVER set sizingOptions = .preferredContentSize.
// ❌ NEVER recreate a remeasurePopover() function.
//
// POPOVEROPENSTATE:
// isOpen mirrors popoverIsOpen. heightReported + onHeightReady drive dynamic sizing.
// Both InlineJobRowsView and PopoverMainView read isOpen as @EnvironmentObject.
// ❌ NEVER pass isPopoverOpen: as a plain Bool prop — frozen at construction time.
// ❌ NEVER remove PopoverOpenState. ❌ NEVER remove wrapEnv() injection.
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
    // Injected via wrapEnv() into every view.
    // isOpen mirrors popoverIsOpen — always set both together.
    // heightReported + onHeightReady drive Architecture 3 dynamic sizing.
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as plain Bool prop to any view — always frozen at construction.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Canonical popover width. NEVER dynamic.
    /// ❌ NEVER change without updating all usages.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    static let fixedWidth: CGFloat = 480

    /// Maximum popover height — 75% of visible screen height.
    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600
    }

    // MARK: - Environment injection

    /// Wraps any view and injects all required environment objects.
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

        // ✅ sizingOptions = [] — ARCHITECTURE 3. CRITICAL. DO NOT CHANGE.
        // Empty [] = hosting controller NEVER auto-writes preferredContentSize.
        // We own ALL contentSize writes exclusively via the onHeightReady callback.
        // ❌ NEVER change to .preferredContentSize — causes side-jump (Architecture 1).
        // ❌ NEVER remove — default is .preferredContentSize which is wrong.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is
        // removed is major major major.
        controller.sizingOptions = []

        let initialSize = NSSize(width: Self.fixedWidth, height: 300)
        controller.view.frame = NSRect(origin: .zero, size: initialSize)
        hostingController = controller

        let pop = NSPopover()
        pop.behavior = .transient
        // ✅ animates = false — CRITICAL for invisible one-shot resize.
        // The popover opens at 300pt then immediately resizes to real content height.
        // animates=false makes this invisible to the user.
        // ❌ NEVER set animates = true — user would see a visible height jump.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
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
            if !self.popoverIsOpen {
                self.observable.reload()
            }
        }
        RunnerStore.shared.start()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        // ❌ NEVER set one without the other.
        // Reset onHeightReady so it cannot fire after close.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverOpenState.isOpen = false
        popoverOpenState.heightReported = false
        popoverOpenState.onHeightReady = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - Navigation

    /// Swaps rootView ONLY. ZERO sizing calls.
    /// ❌ NEVER add sizing calls. ❌ NEVER write contentSize here.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - View factories

    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
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
            }
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

    /// Opens the popover. Architecture 3 sequence:
    ///
    /// 1. Reload data snapshot (async data arrives after show() — that's fine).
    /// 2. Arm the one-shot height callback before show().
    /// 3. Show at safe initial size (300pt). animates=false hides this.
    /// 4. SwiftUI renders real content → GeometryReader fires PreferenceKey.
    /// 5. onPreferenceChange → onHeightReady → setContentSize(real height).
    ///    Because animates=false, user sees final correct height immediately.
    ///
    /// ❌ NEVER call setContentSize after show() except via onHeightReady.
    /// ❌ NEVER call this from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func openPopover() {
        guard let button = statusItem?.button,
              button.window != nil,
              let popover,
              let hostingController else { return }

        // Step 1: snapshot data so header/runners render immediately.
        observable.reload()

        // Step 2: arm open state BEFORE show() so views see isOpen=true on first render.
        // ❌ NEVER move after show(). ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        popoverIsOpen = true
        popoverOpenState.isOpen = true
        popoverOpenState.heightReported = false

        // ⚠️ ONE-SHOT HEIGHT CALLBACK — Architecture 3 dynamic sizing.
        // This closure is called by PopoverMainView's .onPreferenceChange ONCE
        // after the first real layout pass. It calls popover.setContentSize().
        // animates=false (set on the popover) ensures the user never sees the
        // initial 300pt height — the resize happens before the window is drawn.
        //
        // ❌ NEVER call setContentSize inside this closure more than once.
        // ❌ NEVER remove this closure.
        // ❌ NEVER set heightReported = false after show() (that re-arms the callback).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is
        // removed is major major major.
        let maxH = maxHeight
        popoverOpenState.onHeightReady = { [weak popover, weak hostingController] height in
            let clamped = min(height, maxH)
            let finalSize = NSSize(width: Self.fixedWidth, height: clamped)
            hostingController?.view.setFrameSize(finalSize)
            popover?.setContentSize(finalSize)
        }

        // Step 3: set safe initial size and show.
        // The initial 300pt is never seen because animates=false and the
        // onHeightReady callback fires before the first screen draw.
        let safeSize = NSSize(width: Self.fixedWidth, height: 300)
        hostingController.view.setFrameSize(safeSize)
        popover.contentSize = safeSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        // Step 4: restore saved nav state if any.
        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
    }
}

// swiftlint:enable type_body_length
