import AppKit
import SwiftUI

// swiftlint:disable type_body_length file_length

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
// WIDTH: Content-driven via preferredContentSize.width.
// SwiftUI views declare their own minWidth or idealWidth — NO shared fixed width.
//   ActionDetailView: .frame(minWidth: 560, maxWidth: .infinity)
//   JobDetailView:    .frame(idealWidth: 720, maxWidth: .infinity)
// resizeAndRepositionPanel() clamps to [minWidth..maxWidth] and re-centres
// the panel under the status button.
// ❌ NEVER restore idealWidth in ActionDetailView — use minWidth there.
// ❌ NEVER hardcode a fixedWidth — NSPanel has no anchor, any width is safe.
// ❌ NEVER restore minWidth to 560 in AppDelegate — that was the old fixed-width floor.
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
// ❌ NEVER read RunnerStore.shared.jobs for the icon — it will always be 0.
// ❌ NEVER derive the icon from makeStatusIcon() — that function no longer exists.
//    Use AggregateStatus.symbolName with NSImage(systemSymbolName:) instead.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Represents the currently visible navigation screen.
///
/// Persisted in `AppDelegate.savedNavState` so the panel can restore the user's
/// position when it is re-opened after being dismissed. Each case maps 1-to-1 to
/// a view factory method on `AppDelegate`.
private enum NavState {
    /// The root popover showing runners and the recent-actions list.
    /// Created by `mainView()`. `savedNavState` is set to `nil` here (no restore needed).
    case main

    /// The step list for a single job, reached from the Jobs tab.
    /// Created by `detailView(job:)`.
    case jobDetail(ActiveJob)

    /// The raw log for a single step, reached from the Jobs path.
    /// Created by `logView(job:step:)`.
    case stepLog(ActiveJob, JobStep)

    /// The flat job list for a commit/PR action group, reached from the Actions tab.
    /// Created by `actionDetailView(group:)`.
    case actionDetail(ActionGroup)

    /// The step list for a single job reached via the Actions → job-row path.
    /// Created by `detailViewFromAction(job:group:)`.
    case actionJobDetail(ActiveJob, ActionGroup)

    /// The raw log for a single step reached via the Actions → job → step path.
    /// Created by `logViewFromAction(job:step:group:)`.
    case actionStepLog(ActiveJob, JobStep, ActionGroup)

    /// The Settings sheet.
    /// Created by `settingsView()`.
    case settings
}

// MARK: - AppDelegate

// ⚠️ @MainActor ISOLATION CONTRACT — DO NOT REMOVE THIS ANNOTATION.
// AppDelegate runs entirely on the main thread. @MainActor gives the Swift 6
// compiler static proof of this so every method and stored property is verified
// as main-thread-only without any runtime assertion.
//
// The two nonisolated blocking helpers (enrichStepsIfNeeded, enrichGroupIfNeeded)
// are intentionally exempt — they perform blocking network I/O and are always
// dispatched onto DispatchQueue.global() by their callers. nonisolated opts them
// out of the class-level @MainActor domain.
//
// The entry point in main.swift wraps the NSApplicationMain call in
// MainActor.assumeIsolated { }, completing the isolation chain:
//   main.swift (assumeIsolated) → @MainActor AppDelegate → nonisolated helpers
//
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

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel().
    private var panelTopY: CGFloat?

    // ⚠️ REGRESSION GUARD (ref #377):
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as a plain Bool prop to PopoverMainView.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Lower bound for panel content width. Matches minWidth in all SwiftUI root frames.
    /// ❌ NEVER restore to 560 — that was the old fixed-width floor.
    private static let minWidth: CGFloat = 280

    private var maxWidth: CGFloat {
        let screenMax = NSScreen.main.map { $0.visibleFrame.width * 0.9 } ?? 900
        return min(900, screenMax)
    }

    private var maxHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.85 } ?? 700
    }

    private static let gap: CGFloat = 2

    /// Initial panel width used before SwiftUI has measured content.
    /// Does NOT need to match any idealWidth (there are none — width is content-driven).
    /// 320 is a compact default; the panel resizes to actual content on the first KVO fire.
    /// ❌ NEVER set above maxWidth.
    /// ❌ NEVER restore to 600 or 720 — those were the old over-wide defaults.
    private static let initPanelWidth: CGFloat = 320

    // MARK: - Environment injection

    /// ❌ NEVER bypass. ❌ NEVER remove .environmentObject(popoverOpenState).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    /// ALLOWED UNDER ANY CIRCUMSTANCE.
    private func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(popoverOpenState))
    }

    // MARK: - Status icon helpers

    /// Builds the menu bar NSImage from an AggregateStatus using its SF Symbol name.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists. Use this method instead.
    private func menuBarImage(for status: AggregateStatus) -> NSImage {
        NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            ?? NSImage()
    }

    // MARK: - App lifecycle

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
        let chromeView = PanelChromeView(
            frame: NSRect(x: 0, y: 0, width: initW, height: 300 + arrowHeight)
        )
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

    /// Sets the menu bar icon from `RunnerStore.shared.aggregateStatus`.
    ///
    /// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
    /// ❌ NEVER read RunnerStore.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists; use menuBarImage(for:).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func updateStatusIcon() {
        statusItem?.button?.image = menuBarImage(for: RunnerStore.shared.aggregateStatus)
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

        let contentW = min(max(preferred.width, Self.minWidth), maxWidth)
        let contentH = min(max(preferred.height, 60), maxHeight)
        let totalH = contentH + arrowHeight

        let posX = statusItemRect.midX - contentW / 2
        let posY = topY - totalH

        panel.setFrame(NSRect(x: posX, y: posY, width: contentW, height: totalH),
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
        // ⚠️ NAV STATE PERSISTENCE (#385) — DO NOT REMOVE THIS COMMENT.
        // Reset the hosting view to a blank main view WITHOUT calling mainView(),
        // which would set savedNavState = nil and lose the user's position.
        // openPanel() calls validatedView(for: savedNavState) to restore the view.
        // ❌ NEVER replace this with self.mainView() — that wipes savedNavState.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.wrapEnv(PopoverMainView(
                store: self.observable,
                onSelectJob: { _ in },
                onSelectAction: { _ in },
                onSelectSettings: {},
                onSelectInlineJob: { _, _ in }
            ))
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

    // MARK: - Enrichment helpers

    /// Re-fetches steps for a single job when they are missing or still in-progress.
    /// Blocking — always call from a background queue.
    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    /// Re-fetches job data for a group when any run has an empty or incomplete job list.
    ///
    /// Called on a background queue from onSelectAction before navigating to
    /// ActionDetailView. Prevents the detail view opening with a blank job list on
    /// first tap or after a cache miss.
    ///
    /// Strategy: if every job in the group already has a conclusion AND none have
    /// in-progress steps, the group is considered fully enriched and returned as-is.
    /// Otherwise, we re-fetch jobs for all runs in the group and return an enriched copy.
    ///
    /// Blocking — always call from a background queue.
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

    // MARK: - View factories

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
        if panelIsOpen {
            closePanel()
        } else {
            openPanel()
        }
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
        let posX = statusItemRect.midX - initW / 2
        let posY = statusItemRect.minY - initH - Self.gap

        panel.setFrame(
            NSRect(x: posX, y: posY, width: initW, height: initH),
            display: false, animate: false
        )

        chrome?.arrowX = statusItemRect.midX - posX
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
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                self.closePanel()
            }
        }
    }
}
// swiftlint:enable type_body_length
