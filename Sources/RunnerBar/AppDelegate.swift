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
// 2. Position is computed from status button’s window frame (screen coords):
//      statusItemRect = button.window!.frame   ← already in screen coords
//      panelX = statusItemRect.midX - contentW/2   ← re-centred each resize
//      panelY = statusItemRect.minY - clampedContentH - arrowHeight - gap
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
// initW MUST match the widest view’s idealWidth (currently 560 for ActionDetailView).
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
// holds the value computed for the *previous* view’s panel frame. If the new view
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

    // ⚠️ REGRESSION GUARD (ref #377):
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as a plain Bool prop to PopoverMainView.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Minimum panel width. Prevents pathologically narrow views.
    private static let minWidth: CGFloat = 320

    /// Maximum panel width: 90% of main screen width.
    private var maxWidth: CGFloat {
        NSScreen.main.map { $0.visibleFrame.width * 0.9 } ?? 800
    }

    /// Maximum panel height: 85% of main screen height.
    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }

    /// Gap between status bar bottom and arrow tip.
    private static let gap: CGFloat = 2

    /// Initial panel width used in openPanel().
    /// ⚠️ MUST match (or exceed) the largest idealWidth declared by any SwiftUI view.
    /// Currently ActionDetailView declares idealWidth: 560.
    /// If this is smaller than preferredContentSize.width on first render,
    /// arrowX is computed from the wrong frame → arrow appears off-centre.
    /// ✅ Bump this whenever any view’s idealWidth increases.
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
        // ✅ sizingOptions = .preferredContentSize — KVO fires on every SwiftUI size change.
        // ❌ NEVER change to [].
        // ❌ NEVER set autoresizingMask = [] — breaks SwiftUI layout → KVO never fires.
        // ✅ autoresizingMask = [.width, .height] so AppKit propagates panel frame changes
        //    down to the hosting view between KVO fires (belt-and-suspenders).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression is major major major.
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
        // ❌ NEVER set controller.view.frame here only — layout() re-pins it on every resize.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
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
        // ❌ NEVER set backgroundColor = .clear (alpha 0.0).
        // alpha=0.0 disables CABackdropLayer entirely — vibrancy collapses to flat grey.
        // Near-zero (0.001) keeps the backdrop sampler active.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        p.backgroundColor = NSColor(white: 1, alpha: 0.001)
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        panel = p

        // KVO: fires every time SwiftUI content size changes → dynamic height + width.
        // ❌ NEVER remove.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { self?.resizeAndRepositionPanel() }
        }

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(
                for: RunnerStore.shared.aggregateStatus
            )
            // ❌ NEVER call observable.reload() while panelIsOpen == true.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Panel resize (the key to dynamic size without jumping)

    /// Repositions and resizes the panel. Called on every KVO fire + explicitly in openPanel
    /// + synchronously inside navigate(to:) to keep arrowX correct on every view swap.
    ///
    /// Reads BOTH preferredContentSize.width and .height from the hosting controller.
    /// Each SwiftUI view sets its preferred width via .frame(idealWidth: N).
    /// The panel is always re-centred horizontally under the status icon.
    ///
    /// NSPanel.setFrame() has NO anchor concept — zero side jump for any size change.
    /// ❌ NEVER call this on NSPopover.
    /// ❌ NEVER call from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression is major major major.
    private func resizeAndRepositionPanel() {
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let statusItemRect = button.window?.frame else { return }

        let preferred = hostingController?.preferredContentSize ?? CGSize(width: Self.initPanelWidth, height: 300)

        // Clamp width between minWidth and maxWidth.
        let contentW = min(max(preferred.width,  Self.minWidth), maxWidth)
        // Clamp height between a minimum and maxHeight.
        let contentH = min(max(preferred.height, 60),            maxHeight)
        let totalH   = contentH + arrowHeight

        // Always re-centre horizontally under the status icon.
        let x = statusItemRect.midX - contentW / 2
        let y = statusItemRect.minY - totalH - Self.gap

        panel.setFrame(NSRect(x: x, y: y, width: contentW, height: totalH),
                       display: true, animate: false)

        // arrowX: button centre relative to panel left edge.
        // Computed AFTER setFrame so panel.frame.minX is the updated value.
        // ❌ NEVER compute before setFrame — stale minX → arrow offset wrong.
        // ❌ NEVER compute from convertToScreen(button.frame).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        chrome.arrowX = statusItemRect.midX - panel.frame.minX
    }

    // MARK: - Navigation

    /// Swaps the hosted SwiftUI view and immediately re-syncs arrowX.
    ///
    /// ⚠️ ARROW CENTERING: navigate() must always call resizeAndRepositionPanel()
    /// synchronously after swapping rootView. The KVO observer fires the same call
    /// asynchronously, but there is at least one draw frame between the rootView swap
    /// and the async KVO fire. During that frame the old arrowX value is still in
    /// chrome — if the new view has a different width the arrow appears off-centre.
    /// Calling resizeAndRepositionPanel() here closes that gap.
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
        // ❌ NEVER set one without the other.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
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

        // Set open state BEFORE showing so views see isOpen=true on first render.
        // ❌ NEVER move after panel.orderFront().
        panelIsOpen = true
        popoverOpenState.isOpen = true

        // initW MUST match (or exceed) the largest idealWidth in any SwiftUI view (560).
        // If initW < preferredContentSize.width, resizeAndRepositionPanel() shifts the
        // panel left on the first KVO fire — arrowX is then computed from the pre-shift
        // minX and the arrow appears off-centre until the next resize.
        // ✅ initW = initPanelWidth (560) eliminates that first-frame offset entirely.
        let initW = Self.initPanelWidth
        let initH: CGFloat = 300 + arrowHeight
        let x = statusItemRect.midX - initW / 2
        let y = statusItemRect.minY - initH - Self.gap
        panel.setFrame(
            NSRect(x: x, y: y, width: initW, height: initH),
            display: false, animate: false
        )

        // Set arrowX BEFORE orderFront so the very first frame is correct.
        chrome?.arrowX = statusItemRect.midX - x

        panel.orderFront(nil)

        // Snap to real content size + recompute arrowX from the final frame.
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
            guard let self else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                self.closePanel()
            }
        }
    }
}
// swiftlint:enable type_body_length
