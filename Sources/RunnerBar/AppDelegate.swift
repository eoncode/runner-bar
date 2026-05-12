import AppKit
import SwiftUI

// swiftlint:disable type_body_length

// MARK: - NavState

// ⚠️ ARCHITECTURE: NSPanel (Pattern 2 from #377) — READ BEFORE CHANGING.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// WHY NSPanel INSTEAD OF NSPopover:
// NSPopover re-anchors by AppKit design on ANY contentSize change while shown.
// This is not a bug — it is documented intentional behavior. Every attempt to
// dynamically resize NSPopover while visible causes a side-jump. Confirmed across:
//   • #377, #375, #376, #52, #53, #54, #57, #321, #370
//   • Just10/MEMORY.md (identical bug history)
//   • Stack Overflow #14449945, #69877522
// NSPanel has no anchor concept. setFrame() while visible = zero jump, ever.
//
// HOW THE PANEL WORKS:
// 1. Panel is a borderless, non-activating NSPanel.
// 2. Position is computed from status button's window frame (screen coords):
//      statusItemRect = button.window!.frame   ← already in screen coords
//      panelX = statusItemRect.midX - contentW/2   ← re-centred each resize
//      panelTopY = statusItemRect.minY - gap       ← locked at open time
//      y (frame origin) = panelTopY - totalH       ← recomputed each resize
//              ❌ NEVER re-derive panelTopY from statusItemRect inside
//                 resizeAndRepositionPanel() — menu bar hide/show shifts
//                 statusItemRect.minY, moving the panel under the notch.
//      panelH  = clampedContentH + arrowHeight
// 3. arrowX = statusItemRect.midX - panel.frame.minX
//    ❌ NEVER use convertToScreen(button.frame) — button.frame is button-local.
// 4. sizingOptions = .preferredContentSize: KVO on preferredContentSize
//    → resizeAndRepositionPanel() → setFrame(). Zero jump.
// 5. Dismiss: NSEvent global monitor + NSWorkspace app-switch notification.
//
// CHROME DIMENSIONS (match NSPopover exactly):
//   arrowHeight = 9pt, arrowWidth = 30pt, cornerRadius = 10pt
//
// WIDTH: Dynamic per-view via preferredContentSize.width.
// Each SwiftUI view declares .frame(idealWidth: N) to set its preferred width.
// resizeAndRepositionPanel() reads preferredContentSize.width and re-centres.
// Width is clamped to [minWidth..maxWidth].
// ❌ NEVER hardcode a fixedWidth — NSPanel has no anchor, any width is safe.
//
// INITIAL WIDTH (openPanel):
// initW MUST match the widest view's idealWidth (currently 560 for ActionDetailView).
// If initW is smaller than the actual preferredContentSize.width, the first
// resizeAndRepositionPanel() call repositions the panel — but arrowX is computed
// from the *old* frame, producing a stale offset that makes the arrow appear off-centre.
// ✅ Keep initW = 560 (or bump to match whenever idealWidth increases).
// ❌ NEVER set initW smaller than the largest idealWidth in any view.
//
// ARROW CENTERING ON NAVIGATE:
// navigate(to:) swaps rootView synchronously. SwiftUI then schedules a layout pass
// and fires the preferredContentSize KVO — async on the main queue. Between the
// navigate() call and the KVO fire there is at least one frame where arrowX still
// holds the value computed for the *previous* view's panel frame. If the new view
// has a different width, resizeAndRepositionPanel() moves the panel, invalidating
// the stored arrowX. Fix: call resizeAndRepositionPanel() synchronously inside
// navigate(to:) immediately after swapping rootView, so arrowX is always
// recomputed from the current (or new) panel frame before the first draw.
//
// POPOVEROPENSTATE:
// popoverOpenState.isOpen mirrors panelIsOpen. Injected via wrapEnv().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// ❌ NEVER pass as a plain Bool prop to PopoverMainView.
//
// TIMER / POLL GUARD:
// RunnerStore.shared.onChange → observable.reload() gated behind !panelIsOpen.
// ❌ NEVER remove this guard.
//
// DYNAMIC HEIGHT + WIDTH CONTRACT:
// sizingOptions = .preferredContentSize → KVO fires on SwiftUI size change
// → resizeAndRepositionPanel() → panel.setFrame() → chrome.layout() runs
// → hosting view frame = chrome.contentRect (updated) → SwiftUI fills new frame.
// ❌ NEVER set hosting view frame only at init. layout() must always re-pin it.
// ❌ NEVER set autoresizingMask = [] on the hosting view.
//
// STATUS ICON (issue #241):
// updateStatusIcon() counts jobs from ALL groups that have any incomplete job
// (conclusion == nil), regardless of isDimmed. This ensures the icon reflects
// the true in-progress fraction across all active work.
// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
// ❌ NEVER read RunnerStore.shared.jobs for the icon — it will always be 0.
// ❌ NEVER call makeStatusIcon() without job counts — it falls back to solid dot.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var chrome: PanelChromeView?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false

    private var eventMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var workspaceObserver: Any?

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel().
    private var panelTopY: CGFloat?

    // ⚠️ REGRESSION GUARD (ref #377):
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as a plain Bool prop to PopoverMainView.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    private static let minWidth: CGFloat = 320

    private var maxWidth: CGFloat {
        NSScreen.main.map { $0.visibleFrame.width * 0.9 } ?? 800
    }

    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }

    private static let gap: CGFloat = 2

    /// ❌ NEVER set lower than 560.
    private static let initPanelWidth: CGFloat = 560

    // MARK: - Environment injection

    /// ❌ NEVER bypass. ❌ NEVER remove .environmentObject(popoverOpenState).
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
            button.action = #selector(togglePanel)
            button.target = self
        }

        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
        chromeView.addSubview(controller.view)
        chrome = chromeView

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = chromeView
        p.isOpaque = false
        p.backgroundColor = NSColor(white: 1, alpha: 0.001)
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        panel = p

        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { self?.resizeAndRepositionPanel() }
        }

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Status icon

    /// Recomputes and sets the menu bar icon using runner health + action-job progress.
    ///
    /// ⚠️ COUNTS FROM ALL GROUPS WITH ANY INCOMPLETE JOB — NOT JUST !isDimmed.
    ///
    /// isDimmed marks groups that have been frozen into cache after completion, BUT a
    /// dimmed group can still contain in-progress jobs during a transition window.
    /// Filtering by !isDimmed alone means those jobs are invisible to the icon, causing
    /// the icon to show progress for only 2 jobs when 10 are actually running.
    ///
    /// Rule: include a group in the progress count if it has at least one job with
    /// conclusion == nil (i.e. still running or queued). Dimmed groups where every job
    /// has concluded are excluded — they are truly done and must not skew the fraction.
    ///
    /// Progress fraction = completed jobs / total jobs across all active groups.
    /// A job is "completed" when its conclusion != nil (any conclusion counts).
    ///
    /// ❌ NEVER filter by !isDimmed only — misses in-progress jobs in dimmed groups.
    /// ❌ NEVER read RunnerStore.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() without job counts — it falls back to solid dot.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func updateStatusIcon() {
        // Include ALL groups that have at least one incomplete job (conclusion == nil).
        // This covers both non-dimmed (actively displayed) and dimmed groups that are
        // still transitioning — ensuring the icon reflects the true running job count.
        let activeGroups = RunnerStore.shared.actions.filter { group in
            group.jobs.contains { $0.conclusion == nil }
        }
        let allJobs   = activeGroups.flatMap { $0.jobs }
        let total     = allJobs.count
        let completed = allJobs.filter { $0.conclusion != nil }.count
        statusItem?.button?.image = makeStatusIcon(
            for: RunnerStore.shared.aggregateStatus,
            totalJobs: total,
            completedJobs: completed
        )
    }

    // MARK: - Panel resize

    /// ❌ NEVER re-derive panelTopY here.
    /// ❌ NEVER call from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression is major major major.
    private func resizeAndRepositionPanel() {
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let topY = panelTopY else { return }

        let preferred = hostingController?.preferredContentSize ?? CGSize(width: Self.initPanelWidth, height: 300)

        let contentW = min(max(preferred.width,  Self.minWidth), maxWidth)
        let contentH = min(max(preferred.height, 60),            maxHeight)
        let totalH   = contentH + arrowHeight

        let x = statusItemRect.midX - contentW / 2
        let y = topY - totalH

        panel.setFrame(NSRect(x: x, y: y, width: contentW, height: totalH),
                       display: true, animate: false)

        chrome.arrowX = statusItemRect.midX - panel.frame.minX
    }

    // MARK: - Navigation

    /// ❌ NEVER remove the resizeAndRepositionPanel() call from this method.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

    // MARK: - Dismiss

    private func closePanel() {
        guard panelIsOpen else { return }
        panel?.orderOut(nil)
        panelIsOpen = false
        panelTopY = nil
        popoverOpenState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private func removeWorkspaceObserver() {
        if let o = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            workspaceObserver = nil
        }
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
                        guard self.panelIsOpen else { return }
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
                        guard self.panelIsOpen else { return }
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
            group: group,
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

    private func syntheticGroup(for job: ActiveJob) -> ActionGroup {
        let scope = scopeFromHtmlUrl(job.htmlUrl) ?? ""
        return ActionGroup(
            headSha: "",
            label: "",
            title: "",
            headBranch: nil,
            repo: scope,
            runs: []
        )
    }

    private func detailView(job: ActiveJob) -> AnyView {
        savedNavState = .jobDetail(job)
        let group = syntheticGroup(for: job)
        return wrapEnv(JobDetailView(
            job: job,
            group: group,
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
        case .main: return nil
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

    // MARK: - Toggle

    @objc private func togglePanel() {
        panelIsOpen ? closePanel() : openPanel()
    }

    // MARK: - Open

    private func openPanel() {
        guard let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let panel else { return }

        observable.reload()

        panelIsOpen = true
        popoverOpenState.isOpen = true
        panelTopY = statusItemRect.minY - Self.gap

        let initW = Self.initPanelWidth
        let initH: CGFloat = 300 + arrowHeight
        let x = statusItemRect.midX - initW / 2
        let y = statusItemRect.minY - initH - Self.gap

        panel.setFrame(
            NSRect(x: x, y: y, width: initW, height: initH),
            display: false, animate: false
        )

        chrome?.arrowX = statusItemRect.midX - x
        panel.orderFront(nil)
        resizeAndRepositionPanel()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            if !panel.frame.contains(screenLoc) { self.closePanel() }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }\n            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                self.closePanel()
            }
        }
    }
}
// swiftlint:enable type_body_length
