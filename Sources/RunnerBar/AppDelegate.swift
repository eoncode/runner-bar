import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// swiftlint:disable file_length

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
//
// NSPanel + NSWindow.Level.popUpMenu is the ONLY pattern that:
//   a) stays anchored while content resizes
//   b) appears above fullscreen spaces
//   c) hides when another app is focused (via applicationDidResignActive)
//   d) does not block keyboard input to other apps
// Pattern 2 was chosen after testing all five NSPanel patterns (see PR #377).
//
// ❌ NEVER switch back to NSPopover.
// ❌ NEVER use NSWindow.Level.floating — it blocks keyboard in other apps.
// ❌ NEVER use NSWindow.Level.normal — panel hides under fullscreen spaces.
// ❌ NEVER call show(relativeTo:of:preferredEdge:) — only openPanel() below.

enum NavState: Equatable {
    /// The root popover showing runners and the recent-actions list.
    /// Created by `mainView()`. `savedNavState` is set to `nil` here (no restore needed).
    case main
    /// The step list for a single job, reached from the Jobs tab.
    /// Created by `detailView(job:)`.
    case detail(job: ActiveJob)
    /// The raw log for a single step, reached from the Jobs path.
    /// Created by `logView(job:step:)`.
    case log(job: ActiveJob, step: Step)
    /// The flat job list for a commit/PR action group, reached from the Actions tab.
    /// Created by `actionDetailView(group:)`.
    case actionDetail(group: ActionGroup)
    /// The step list for a single job reached via the Actions → job-row path.
    /// Created by `detailViewFromAction(job:group:)`.
    case detailFromAction(job: ActiveJob, group: ActionGroup)
    /// The raw log for a single step reached via the Actions → job → step path.
    /// Created by `logViewFromAction(job:step:group:)`.
    case logFromAction(job: ActiveJob, step: Step, group: ActionGroup)
    /// The Settings sheet.
    /// Created by `settingsView()`.
    case settings
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // MARK: - Panel
    var panel: NSPanel?

    // MARK: - Navigation
    @Published var navState: NavState = .main
    var savedNavState: NavState?

    // MARK: - Metrics
    private let systemStats = SystemStatsViewModel()

    // MARK: - Geometry constants

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel().
    private var panelTopY: CGFloat = 0

    /// Minimum content width floor.
    /// ❌ NEVER reduce below 280 without reviewing each view's minWidth.
    private let minContentWidth: CGFloat = 280

    /// Maximum width the panel may expand to.
    private let maxWidth: CGFloat = 480

    /// Preferred panel width for detail / log views.
    private let detailWidth: CGFloat = 420

    /// Width for the settings view.
    private let settingsWidth: CGFloat = 420

    /// Lower bound for panel content width (clamp floor in resizeAndRepositionPanel).
    /// Views declare their own, larger minWidth/idealWidth — this is the AppDelegate floor only.
    /// ❌ NEVER change from 280 without also reviewing each view's own minWidth/idealWidth.
    private let panelMinWidth: CGFloat = 280

    // MARK: - Status bar
    private var statusItem: NSStatusItem?
    private var eventMonitor: Any?

    // MARK: - Environment injection
    let popoverOpenState = PopoverOpenState()

    /// ❌ NEVER bypass. ❌ NEVER remove .environmentObject(popoverOpenState).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    /// ALLOWED UNDER ANY CIRCUMSTANCE.
    private lazy var hostingController: NSHostingController<AnyView> = {
        let view = AnyView(
            PopoverView()
                .environmentObject(RunnerStore.shared)
                .environmentObject(RunnerStoreObservable.shared)
                .environmentObject(popoverOpenState)
                .environmentObject(systemStats)
        )
        return NSHostingController(rootView: view)
    }()

    // MARK: - Status icon helpers

    /// Builds the menu bar NSImage from an AggregateStatus using its SF Symbol name.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists. Use this method instead.
    private func menuBarImage(for status: AggregateStatus) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: status.sfSymbolName, accessibilityDescription: status.rawValue)
            .flatMap { $0.withSymbolConfiguration(config) }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        systemStats.start()
        RunnerStore.shared.onSelectJob = { [weak self] job in
            DispatchQueue.main.async { self?.onSelectJob(job) }
        }
        RunnerStore.shared.onSelectAction = { [weak self] group in
            self?.onSelectAction(group)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(runnerStoreDidRefresh),
            name: .runnerStoreDidRefresh,
            object: nil
        )
    }

    @objc private func runnerStoreDidRefresh() {
        DispatchQueue.main.async { self.updateStatusIcon() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemStats.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
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
        let status = RunnerStore.shared.aggregateStatus
        statusItem?.button?.image = menuBarImage(for: status)
    }

    // MARK: - Panel resize

    /// ❌ NEVER re-derive panelTopY here.
    /// ❌ NEVER call from a background thread.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression is major major major.
    func resizeAndRepositionPanel(width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
        let currentFrame = panel.frame
        let newWidth = (width.map { max(panelMinWidth, min(maxWidth, $0)) } ?? currentFrame.width)
        let newHeight = height ?? currentFrame.height
        let buttonFrame = statusItem?.button?.window?.frame ?? .zero
        let buttonMidX = buttonFrame.midX
        var newX = buttonMidX - newWidth / 2
        newX = max(screen.visibleFrame.minX, min(screen.visibleFrame.maxX - newWidth, newX))
        let newY = panelTopY - newHeight
        panel.setFrame(NSRect(x: newX, y: newY, width: newWidth, height: newHeight), display: true, animate: false)
    }

    // MARK: - Navigation

    /// ❌ NEVER remove the resizeAndRepositionPanel() call from this method.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func navigate(to state: NavState) {
        DispatchQueue.main.async {
            self.navState = state
            self.resizeAndRepositionPanel()
        }
    }

    // MARK: - Dismiss

    @objc private func onSelectJob(_ job: ActiveJob) {
        openPanel()
        DispatchQueue.global(qos: .userInitiated).async {
            let enriched = self.enrichJobIfNeeded(job)
            DispatchQueue.main.async { self.navigate(to: .detail(job: enriched)) }
        }
    }

    private func onSelectAction(_ group: ActionGroup) {
        openPanel()
        DispatchQueue.global(qos: .userInitiated).async {
            let enriched = self.enrichGroupIfNeeded(group)
            DispatchQueue.main.async { self.navigate(to: .actionDetail(group: enriched)) }
        }
    }

    func navigateToDetail(job: ActiveJob) {
        navigate(to: .detail(job: job))
    }

    func navigateToLog(job: ActiveJob, step: Step) {
        navigate(to: .log(job: job, step: step))
    }

    func navigateToDetailFromAction(job: ActiveJob, group: ActionGroup) {
        navigate(to: .detailFromAction(job: job, group: group))
    }

    func navigateToLogFromAction(job: ActiveJob, step: Step, group: ActionGroup) {
        navigate(to: .logFromAction(job: job, step: step, group: group))
    }

    func navigateToSettings() {
        navigate(to: .settings)
    }

    func navigateBack() {
        navigate(to: savedNavState ?? .main)
    }

    func navigateToMain() {
        navigate(to: .main)
    }

    // MARK: - Enrichment helpers

    /// Re-fetches steps for a single job when they are missing or still in-progress.
    /// Blocking — always call from a background queue.
    private func enrichJobIfNeeded(_ job: ActiveJob) -> ActiveJob {
        let needsEnrich = job.steps.isEmpty || job.steps.contains { $0.status == .inProgress }
        guard needsEnrich else { return job }
        let steps = GitHub.fetchSteps(owner: job.owner, repo: job.repo, jobID: job.id)
        guard !steps.isEmpty else { return job }
        return ActiveJob(
            id: job.id, owner: job.owner, repo: job.repo,
            name: job.name, status: job.status, conclusion: job.conclusion,
            startedAt: job.startedAt, completedAt: job.completedAt,
            runID: job.runID, steps: steps, runnerName: job.runnerName
        )
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
    private func enrichGroupIfNeeded(_ group: ActionGroup) -> ActionGroup {
        let allDone = group.runs.allSatisfy { run in
            !run.jobs.isEmpty && run.jobs.allSatisfy { $0.conclusion != nil }
                && !run.jobs.flatMap(\.steps).contains { $0.status == .inProgress }
        }
        guard !allDone else { return group }
        var enrichedRuns = group.runs
        for idx in enrichedRuns.indices {
            let run = enrichedRuns[idx]
            let jobs = GitHub.fetchJobs(owner: group.owner, repo: group.repo, runID: run.id)
            guard !jobs.isEmpty else { continue }
            let enrichedJobs: [ActiveJob] = jobs.map { job in
                let steps = GitHub.fetchSteps(owner: group.owner, repo: group.repo, jobID: job.id)
                return ActiveJob(
                    id: job.id, owner: job.owner, repo: job.repo,
                    name: job.name, status: job.status, conclusion: job.conclusion,
                    startedAt: job.startedAt, completedAt: job.completedAt,
                    runID: job.runID, steps: steps.isEmpty ? job.steps : steps,
                    runnerName: job.runnerName
                )
            }
            enrichedRuns[idx] = WorkflowRun(
                id: run.id, name: run.name, headBranch: run.headBranch,
                headSha: run.headSha, status: run.status, conclusion: run.conclusion,
                createdAt: run.createdAt, updatedAt: run.updatedAt,
                htmlUrl: run.htmlUrl, jobs: enrichedJobs,
                pullRequests: run.pullRequests
            )
        }
        return ActionGroup(
            owner: group.owner, repo: group.repo,
            commitSha: group.commitSha, commitMessage: group.commitMessage,
            authorLogin: group.authorLogin, createdAt: group.createdAt,
            runs: enrichedRuns, isDimmed: group.isDimmed
        )
    }

    // MARK: - View factories

    private func mainView() -> AnyView {
        savedNavState = nil
        return AnyView(PopoverMainView())
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(JobDetailView(job: job, onBack: { [weak self] in self?.navigateBack() }))
    }

    private func logView(job: ActiveJob, step: Step) -> AnyView {
        AnyView(StepLogView(job: job, step: step, onBack: { [weak self] in self?.navigateBack() }))
    }

    private func actionDetailView(group: ActionGroup) -> AnyView {
        AnyView(ActionDetailView(
            group: group,
            onBack: { [weak self] in self?.navigateBack() },
            onSelectJob: { [weak self] job in self?.navigateToDetailFromAction(job: job, group: group) }
        ))
    }

    private func detailViewFromAction(job: ActiveJob, group: ActionGroup) -> AnyView {
        AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in self?.navigate(to: .actionDetail(group: group)) },
            onSelectStep: { [weak self] step in
                self?.navigateToLogFromAction(job: job, step: step, group: group)
            }
        ))
    }

    private func logViewFromAction(job: ActiveJob, step: Step, group: ActionGroup) -> AnyView {
        AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in self?.navigate(to: .detailFromAction(job: job, group: group)) }
        ))
    }

    private func settingsView() -> AnyView {
        AnyView(SettingsView(onDismiss: { [weak self] in
            guard let self else { return }
            if let saved = savedNavState {
                navigate(to: saved)
            } else {
                navigateToMain()
            }
        }))
    }

    @ViewBuilder
    func currentView() -> some View {
        switch navState {
        case .main:
            mainView()
        case let .detail(job):
            detailView(job: job)
        case let .log(job, step):
            logView(job: job, step: step)
        case let .actionDetail(group):
            actionDetailView(group: group)
        case let .detailFromAction(job, group):
            detailViewFromAction(job: job, group: group)
        case let .logFromAction(job, step, group):
            logViewFromAction(job: job, step: step, group: group)
        case .settings:
            settingsView()
        }
    }

    // MARK: - Toggle

    @objc func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: - Open

    func openPanel() {
        if panel == nil { setupPanel() }
        guard let panel = panel else { return }
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panelTopY = buttonFrame.minY
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 400
        let buttonMidX = buttonFrame.midX
        var newX = buttonMidX - panelWidth / 2
        newX = max(screen.visibleFrame.minX, min(screen.visibleFrame.maxX - panelWidth, newX))
        let newY = panelTopY - panelHeight
        panel.setFrame(NSRect(x: newX, y: newY, width: panelWidth, height: panelHeight), display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popoverOpenState.isOpen = true
        systemStats.start()
        setupEventMonitor()
    }

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.delegate = self
        self.panel = panel
    }

    func closePanel() {
        panel?.orderOut(nil)
        popoverOpenState.isOpen = false
        systemStats.stop()
        tearDownEventMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.action = #selector(togglePanel)
        statusItem?.button?.target = self
        updateStatusIcon()
        RunnerStore.shared.start()
    }

    private func setupEventMonitor() {
        tearDownEventMonitor()
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let loc = event.locationInWindow
            let screenLoc = event.window?.convertToScreen(NSRect(origin: loc, size: .zero)).origin ?? loc
            if !panel.frame.contains(screenLoc) {
                self.closePanel()
            }
        }
    }

    private func tearDownEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async {
            if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication { self.closePanel() }
        }
    }
}
// swiftlint:enable type_body_length file_length
