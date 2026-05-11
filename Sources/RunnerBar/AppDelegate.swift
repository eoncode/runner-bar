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
// NSPanel has no anchor concept. setFrame() while visible = zero jump, ever.
//
// HOW THE PANEL WORKS:
// 1. Borderless, non-activating NSPanel.
// 2. Position computed from status button screen frame.
// 3. NSHostingController.sizingOptions = .preferredContentSize
//    KVO on preferredContentSize → resizeAndRepositionPanel() → setFrame().
//    Zero side jump — no anchor.
// 4. Dismiss: NSEvent monitor + NSWorkspace.didActivateApplication.
//
// VISUAL CHROME:
// • cornerRadius=12 applied to hostingController.view.layer (rounded corners).
// • PanelArrowWindow: separate tiny child panel draws the arrow caret.
//   It is shown/hidden/repositioned alongside the main panel.
//   ❌ NEVER fold arrow into main panel frame — that breaks content layout.
//
// WIDTH RULE: fixedWidth=480. Never dynamic.
// POPOVEROPENSTATE: mirrors panelIsOpen. ❌ NEVER remove from wrapEnv().
// TIMER GUARD: onChange reload gated behind !panelIsOpen. ❌ NEVER remove.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
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
    private var arrowWindow: PanelArrowWindow?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false

    private var eventMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var workspaceObserver: Any?

    // ⚠️ REGRESSION GUARD (ref #377): ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    private let popoverOpenState = PopoverOpenState()

    private static let fixedWidth: CGFloat = 480
    private static let gap: CGFloat = 4   // gap between arrow tip and status button bottom

    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }

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
        // ✅ sizingOptions=.preferredContentSize: KVO fires on SwiftUI size change.
        // ❌ NEVER change to [].
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = controller
        p.isOpaque = true
        p.backgroundColor = .windowBackgroundColor
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        panel = p

        // Rounded corners: applied to the hosting view layer.
        // isOpaque must stay true — the layer mask clips content correctly.
        // ❌ NEVER set cornerRadius on the panel itself (NSPanel ignores it).
        if let layer = controller.view.layer {
            layer.cornerRadius = 12
            layer.masksToBounds = true
        }

        // Arrow caret: separate tiny transparent panel.
        arrowWindow = PanelArrowWindow()

        // KVO: dynamic height, zero jump.
        // ❌ NEVER remove.
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.resizeAndRepositionPanel() }
        }

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ❌ NEVER call observable.reload() while panelIsOpen == true.
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Panel resize

    private func resizeAndRepositionPanel() {
        guard panelIsOpen,
              let panel,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let contentH = hostingController?.preferredContentSize.height ?? 300
        let h = min(max(contentH, 60), maxHeight)
        let w = Self.fixedWidth
        let x = buttonScreenFrame.midX - w / 2
        let y = buttonScreenFrame.minY - h - arrowH - Self.gap

        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
        arrowWindow?.reposition(buttonMidX: buttonScreenFrame.midX, panelTop: y + h)
    }

    // MARK: - Navigation

    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - Dismiss

    private func closePanel() {
        guard panelIsOpen else { return }
        panel?.orderOut(nil)
        arrowWindow?.orderOut(nil)
        panelIsOpen = false
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

        // Set open state BEFORE showing. ❌ NEVER move after orderFront().
        panelIsOpen = true
        popoverOpenState.isOpen = true

        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let initH: CGFloat = 300
        let x = buttonScreenFrame.midX - Self.fixedWidth / 2
        let y = buttonScreenFrame.minY - initH - arrowH - Self.gap

        panel.setFrame(NSRect(x: x, y: y, width: Self.fixedWidth, height: initH), display: false, animate: false)
        panel.orderFront(nil)

        arrowWindow?.reposition(buttonMidX: buttonScreenFrame.midX, panelTop: y + initH)
        arrowWindow?.orderFront(nil)

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(NSRect(origin: loc, size: .zero)).origin ?? loc
            // Hit-test both main panel and arrow window
            let arrowFrame = self.arrowWindow?.frame ?? .zero
            if !panel.frame.contains(screenLoc) && !arrowFrame.contains(screenLoc) {
                self.closePanel()
            }
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
