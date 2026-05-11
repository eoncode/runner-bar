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
// 2. Position is computed from status button screen frame:
//      panelX = buttonMidX - fixedWidth/2
//      panelY = buttonMinY - clampedContentH - arrowHeight - gap
//      panelH  = clampedContentH + arrowHeight
// 3. sizingOptions = .preferredContentSize: SwiftUI auto-updates
//    hostingController.preferredContentSize as content changes.
//    KVO on preferredContentSize → resizeAndRepositionPanel() → setFrame().
//    NSPanel.setFrame() while visible = zero side jump (no anchor concept).
// 4. arrowX = buttonScreenFrame.midX - panel.frame.minX
//    Updated on every reposition so arrow always points at the status icon.
// 5. Dismiss: NSEvent global monitor + NSWorkspace app-switch notification.
//
// CHROME (PanelChromeView):
//   contentView = PanelChromeView.
//   ❌ NEVER set chrome.frame manually — AppKit owns contentView.frame.
//   chrome.layout() pins fx to contentRect ONLY.
//   Hosting view has autoresizingMask=[.width,.height] — AppKit fills it.
//   ❌ NEVER set autoresizingMask=[] on the hosting view.
//   ❌ NEVER override the hosting view frame in layout() — breaks KVO.
//
// WIDTH RULE:
// Width is ALWAYS fixedWidth=480. Never dynamic. Never fittingSize.width.
// ❌ NEVER change fixedWidth without updating it everywhere.
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

    /// Canonical panel width. NEVER dynamic. NEVER fittingSize.width.
    /// ❌ NEVER change without updating all usages.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private static let fixedWidth: CGFloat = 480

    /// Gap between status bar button bottom and arrow tip.
    private static let gap: CGFloat = 2

    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }

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
        // Safe with NSPanel: setFrame() has no anchor, zero jump.
        // ❌ NEVER change to [].
        // ❌ NEVER set autoresizingMask=[] on controller.view — doing so prevents SwiftUI
        //    from rendering at its natural height, breaking preferredContentSize KVO.
        //    autoresizingMask=[.width,.height] lets AppKit fill the hosting view as the
        //    panel grows, so SwiftUI can report the real preferredContentSize.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression is major major major.
        controller.sizingOptions = .preferredContentSize
        // ✅ autoresizingMask=[.width,.height]: hosting view fills chrome as panel grows.
        // This breaks the chicken-and-egg where SwiftUI was stuck at init height (300pt)
        // because layout() kept resetting the frame before KVO could fire.
        // ❌ NEVER set to [] — see architecture comment above.
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 300 + arrowHeight)
        )
        chromeView.addSubview(controller.view)
        controller.view.frame = chromeView.contentRect
        chrome = chromeView

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 300 + arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = chromeView
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        panel = p

        // KVO: observe preferredContentSize — fires every time SwiftUI content height changes.
        // Drives dynamic height: resizeAndRepositionPanel() → panel.setFrame() → zero jump.
        // ❌ NEVER remove this observation.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            // Only resize if the new height is a real non-zero value.
            guard let h = change.newValue?.height, h > 0 else { return }
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

    // MARK: - Panel resize (the key to dynamic height without jumping)

    /// Repositions and resizes the panel based on current preferredContentSize
    /// and the status button's screen frame. Called on every KVO fire AND
    /// explicitly in openPanel() after orderFront for the initial snap.
    ///
    /// arrowX is recomputed here from the final settled panel X so the arrow
    /// always points directly at the centre of the status bar icon.
    ///
    /// NSPanel.setFrame() has NO anchor concept — zero side jump, ever.
    /// ❌ NEVER set chrome.frame here — AppKit owns contentView.frame.
    /// ❌ NEVER call this on NSPopover.
    /// ❌ NEVER call from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression is major major major.
    private func resizeAndRepositionPanel() {
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let contentH = hostingController?.preferredContentSize.height ?? 300
        let clampedH = min(max(contentH, 60), maxHeight)
        let totalH   = clampedH + arrowHeight
        let w        = Self.fixedWidth
        // Panel is centered horizontally under the status bar icon.
        let x        = buttonScreenFrame.midX - w / 2
        let y        = buttonScreenFrame.minY - totalH - Self.gap

        panel.setFrame(NSRect(x: x, y: y, width: w, height: totalH), display: true, animate: false)

        // arrowX: distance from panel left edge to button centre.
        // Computed AFTER panel.setFrame() so x is the final settled panel origin.
        // ❌ NEVER compute arrowX before panel.setFrame().
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        chrome.arrowX = buttonScreenFrame.midX - x
    }

    // MARK: - Navigation

    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
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
              let buttonWindow = button.window,
              let panel else { return }

        observable.reload()

        // Set open state BEFORE showing so views see isOpen=true on first render.
        // ❌ NEVER move after panel.orderFront().
        panelIsOpen = true
        popoverOpenState.isOpen = true

        // Show at placeholder height first, then snap immediately via
        // resizeAndRepositionPanel() which uses the real preferredContentSize.
        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let initH: CGFloat = 300 + arrowHeight
        let x = buttonScreenFrame.midX - Self.fixedWidth / 2
        let y = buttonScreenFrame.minY - initH - Self.gap
        panel.setFrame(
            NSRect(x: x, y: y, width: Self.fixedWidth, height: initH),
            display: false, animate: false
        )

        panel.orderFront(nil)

        // Snap to real content height immediately.
        // Also correctly sets arrowX from the final settled panel position.
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
