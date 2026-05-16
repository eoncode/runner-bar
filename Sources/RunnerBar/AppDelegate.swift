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
// • #377, #375, #376, #52, #53, #54, #57, #321, #370
// • Just10/MEMORY.md (identical bug history)
// • Stack Overflow #14449945, #69877522
// NSPanel has no anchor concept. setFrame() while visible = zero jump, ever.
//
// HOW THE PANEL WORKS:
// 1. Panel is a borderless, non-activating NSPanel.
// 2. Position is computed from status button's window frame (screen coords):
//    statusItemRect = button.window!.frame ← already in screen coords
//    panelX = statusItemRect.midX - contentW/2 ← re-centred each resize
//    panelTopY = statusItemRect.minY - gap ← locked at open time
//    y (frame origin) = panelTopY - totalH ← recomputed each resize
//    ❌ NEVER re-derive panelTopY from statusItemRect inside
//       resizeAndRepositionPanel() — menu bar hide/show shifts
//       statusItemRect.minY, moving the panel under the notch.
//    panelH = clampedContentH + arrowHeight
// 3. arrowX = statusItemRect.midX - panel.frame.minX
//    ❌ NEVER use convertToScreen(button.frame) — button.frame is button-local.
// 4. sizingOptions = .preferredContentSize: KVO on preferredContentSize
//    → resizeAndRepositionPanel() → setFrame(). Zero jump.
// 5. Dismiss: NSEvent global monitor + NSWorkspace app-switch notification.
//
// CHROME DIMENSIONS (match NSPopover exactly):
// arrowHeight = 9pt, arrowWidth = 30pt, cornerRadius = 10pt
//
// WIDTH: Content-driven via preferredContentSize.width.
// SwiftUI views declare their own minWidth or idealWidth — NO shared fixed width.
// ActionDetailView: .frame(minWidth: 560, maxWidth: .infinity)
// JobDetailView: .frame(idealWidth: 720, maxWidth: .infinity)
// resizeAndRepositionPanel() clamps to [minWidth..maxWidth] and re-centres
// the panel under the status button.
// ❌ NEVER restore idealWidth in ActionDetailView — use minWidth there.
// ❌ NEVER hardcode a fixedWidth — NSPanel has no anchor, any width is safe.
// ❌ NEVER remove minWidth: 560 from ActionDetailView — AppDelegate's floor (minWidth = 280)
//    is lower; ActionDetailView needs its own content minWidth of 560.
//
// INITIAL WIDTH (openPanel):
// initPanelWidth is the fallback frame width used for the initial open before
// SwiftUI has measured anything. It does NOT need to match any idealWidth (there
// are none). 320 is a compact default; the panel resizes to actual content on the
// first preferredContentSize KVO fire.
// ❌ NEVER set initPanelWidth > maxWidth.
// ❌ NEVER restore initPanelWidth to 600 — that was wider than necessary.
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
// updateStatusIcon() sets the menu bar image from RunnerStore.shared.aggregateStatus.
// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
// ❌ NEVER read RunnerStore.shared.jobs for the icon — it is almost always empty.
// ❌ NEVER derive the icon from makeStatusIcon() — that function no longer exists.
// Use AggregateStatus.symbolName with NSImage(systemSymbolName:) instead.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Represents the currently visible navigation screen.
///
/// Persisted in `AppDelegate.savedNavState` so the panel can restore the user's
/// position when it is re-opened after being dismissed.
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

// ⚠️ @MainActor ISOLATION CONTRACT — DO NOT REMOVE THIS ANNOTATION.
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded or enrichGroupIfNeeded.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
@MainActor
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
    private var panelTopY: CGFloat?
    private let popoverOpenState = PopoverOpenState()

    private static let minWidth: CGFloat = 280
    private var maxWidth: CGFloat {
        let screenMax = NSScreen.main.map { $0.visibleFrame.width * 0.9 } ?? 900
        return min(900, screenMax)
    }
    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }
    private static let gap: CGFloat = 2
    private static let initPanelWidth: CGFloat = 320

    private func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(popoverOpenState))
    }

    private func menuBarImage(for status: AggregateStatus) -> NSImage {
        NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            ?? NSImage()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = menuBarImage(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let initW = Self.initPanelWidth
        let chromeView = PanelChromeView(frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight))
        chromeView.addSubview(controller.view)
        chrome = chromeView

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = chromeView
        newPanel.isOpaque = false
        newPanel.backgroundColor = NSColor(white: 1, alpha: 0.001)
        newPanel.hasShadow = true
        newPanel.level = .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.animationBehavior = .none
        panel = newPanel

        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async { self?.resizeAndRepositionPanel() }
        }

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
        _ = notification
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = menuBarImage(for: RunnerStore.shared.aggregateStatus)
    }

    private func resizeAndRepositionPanel() {
        guard panelIsOpen,
              let panel,
              let chrome,
              let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let topY = panelTopY else { return }
        let preferred = hostingController?.preferredContentSize ?? CGSize(width: Self.initPanelWidth, height: 300)
        let contentW = min(max(preferred.width, Self.minWidth), maxWidth)
        let contentH = min(max(preferred.height, 60), maxHeight)
        let totalH = contentH + arrowHeight
        let posX = statusItemRect.midX - contentW / 2
        let posY = topY - totalH
        panel.setFrame(NSRect(x: posX, y: posY, width: contentW, height: totalH), display: true, animate: false)
        chrome.arrowX = statusItemRect.midX - panel.frame.minX
    }

    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
    }

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
            let preserved = self.savedNavState
            self.hostingController?.rootView = self.mainView()
            self.savedNavState = preserved
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }

    private func removeWorkspaceObserver() {
        if let opt = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(opt)
            workspaceObserver = nil
        }
    }

    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    // swiftlint:disable:next cyclomatic_complexity
    nonisolated private func enrichGroupIfNeeded(_ group: ActionGroup) -> ActionGroup {
        let fullyEnriched = !group.jobs.isEmpty
            && group.jobs.allSatisfy { $0.conclusion != nil }
            && !group.jobs.contains { $0.steps.contains { $0.status == "in_progress" } }
        guard !fullyEnriched else { return group }
        let iso = ISO8601DateFormatter()
        var fetched: [ActiveJob] = []
        var seenIDs = Set<Int>()
        for run in group.runs {
            guard let data = ghAPI("repos/\(group.repo)/actions/runs/\(run.id)/jobs?per_page=100"),
                  let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
            else { continue }
            for payload in resp.jobs where seenIDs.insert(payload.id).inserted {
                fetched.append(makeActiveJob(from: payload, iso: iso, isDimmed: group.isDimmed))
            }
        }
        guard !fetched.isEmpty else { return group }
        fetched.sort { $0.id < $1.id }
        let starts = fetched.compactMap { $0.startedAt }
        let ends = fetched.compactMap { $0.completedAt }
        return ActionGroup(
            headSha: group.headSha,
            label: group.label,
            title: group.title,
            headBranch: group.headBranch,
            repo: group.repo,
            runs: group.runs,
            jobs: fetched,
            firstJobStartedAt: starts.min() ?? group.firstJobStartedAt,
            lastJobCompletedAt: ends.max() ?? group.lastJobCompletedAt,
            createdAt: group.createdAt,
            isDimmed: group.isDimmed
        )
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
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichGroupIfNeeded(latest)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.actionDetailView(group: enriched))
                    }
                }
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            },
            onSelectInlineJob: { [weak self] job, group in
                guard let self else { return }
                let latestGroup = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.detailViewFromAction(job: enriched, group: latestGroup))
                    }
                }
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
        return ActionGroup(headSha: "", label: "", title: "", headBranch: nil, repo: scope, runs: [])
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

    // swiftlint:disable:next cyclomatic_complexity
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

    @objc private func togglePanel() {
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    private func addEventMonitor(statusItemRect: NSRect) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: loc, size: .zero)
            ).origin ?? loc
            if !panel.frame.contains(screenLoc) { self.closePanel() }
        }
        _ = statusItemRect
    }

    private func addWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                self.closePanel()
            }
        }
    }

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
        let posX = statusItemRect.midX - initW / 2
        let posY = statusItemRect.minY - initH - Self.gap
        panel.setFrame(NSRect(x: posX, y: posY, width: initW, height: initH), display: false, animate: false)
        chrome?.arrowX = statusItemRect.midX - posX
        panel.orderFront(nil)
        resizeAndRepositionPanel()
        if let saved = savedNavState, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
        addEventMonitor(statusItemRect: statusItemRect)
        addWorkspaceObserver()
    }
}

// swiftlint:enable type_body_length
