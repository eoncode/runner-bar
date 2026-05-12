import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #375 #376 #377)
//
// ARCHITECTURE IN USE: NSPanel (PanelChrome) — NOT NSPopover
//
// WHY NSPopover WAS REPLACED:
//   NSPopover re-anchors (left-jumps) on ANY contentSize change while shown.
//   No public API exists to suppress this. PanelChrome owns the window frame
//   and resizes in-place via updateHeight() — the arrow stays pinned to the
//   status bar button centre. No re-anchor is possible.
//
// HEIGHT STRATEGY: HeightPreferenceKey (HeightReporter.swift)
//   Each view factory appends .reportHeight(to: self).
//   didUpdateHeight() is called on the main thread whenever rendered height
//   changes and calls panel.updateHeight() for an in-place resize.
//
// CONTRACT (DO NOT VIOLATE ANY RULE):
//   ✅ AppDelegate conforms to HeightReceiver.
//   ✅ Every view factory ends with .reportHeight(to: self).
//   ✅ openPanel() calls panel.positionBelow() once — no re-position on resize.
//   ❌ NEVER reintroduce NSPopover — the jump cannot be fixed.
//   ❌ NEVER replace HeightPreferenceKey with fittingSize — unreliable pre-layout.
//   ❌ NEVER call positionBelow() from didUpdateHeight() — re-anchors every resize.
//   ❌ NEVER reload() before panelIsOpen = true — race with onChange.
//
// WHY systemStats IS STOPPED WHILE PANEL IS OPEN (ref #375 #376 #377 — CPU GUARD):
//   systemStats fires @Published every ~1s. It is stopped while the panel is
//   open to save CPU. isPopoverOpen passed to PopoverMainView controls this.
// ❌ NEVER remove the isPopoverOpen parameter from PopoverMainView — it stops systemStats.
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

final class AppDelegate: NSObject, NSApplicationDelegate, HeightReceiver, @unchecked Sendable {

    // Fixed canvas width — PanelChrome and all views use this.
    static let fixedWidth: CGFloat = 420

    private var statusItem: NSStatusItem?
    private(set) var panel: PanelChrome?
    private var hostingController: NSHostingController<AnyView>?
    @MainActor private lazy var observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false

    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.85
    }

    // MARK: - HeightReceiver
    // Called on main thread by HeightReporter whenever rendered content height changes.
    // Calls panel.updateHeight() for in-place resize — no re-anchor possible.
    // ❌ NEVER call positionBelow() here — that re-anchors the panel.
    // ❌ NEVER call this from a timer or store update.
    func didUpdateHeight(_ height: CGFloat) {
        guard panelIsOpen, let panel, panel.isVisible, height > 0 else { return }
        let clamped = min(height, maxContentHeight)
        panel.updateHeight(clamped)
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
        controller.sizingOptions = []
        // Give the hosting view a real width so SwiftUI can compute height.
        controller.view.frame = NSRect(origin: .zero,
                                       size: NSSize(width: Self.fixedWidth, height: 10))
        hostingController = controller

        let chrome = PanelChrome()
        chrome.onClose = { [weak self] in self?.panelDidClose() }
        chrome.hostingView = controller.view
        panel = chrome

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            if !self.panelIsOpen {
                DispatchQueue.main.async { self.observable.reload() }
            }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Panel lifecycle

    func panelDidClose() {
        panelIsOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingController?.rootView = self.mainView()
        }
    }

    // MARK: - View factories
    // Each factory appends .reportHeight(to: self) so didUpdateHeight() fires whenever
    // the rendered content height changes.

    private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty
                || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        return makeActiveJob(from: fresh, iso: ISO8601DateFormatter(), isDimmed: job.isDimmed)
    }

    @MainActor
    private func mainView() -> AnyView {
        savedNavState = nil
        return AnyView(PopoverMainView(
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
            },
            isPopoverOpen: panelIsOpen
        ).reportHeight(to: self))
    }

    // ⚠️ openPanelView() — identical to mainView() but always passes isPopoverOpen: true.
    // Used ONLY inside openPanel() so systemStats is stopped on first render (CPU guard).
    // ❌ NEVER use mainView() inside openPanel().
    // ❌ NEVER use this method anywhere except openPanel().
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @MainActor
    private func openPanelView() -> AnyView {
        savedNavState = nil
        return AnyView(PopoverMainView(
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
            },
            // ⚠️ CRITICAL: literal true — CPU guard, stops systemStats on first render.
            // ❌ NEVER change to panelIsOpen here.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            isPopoverOpen: true
        ).reportHeight(to: self))
    }

    @MainActor
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
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.detailViewFromAction(job: enriched, group: group))
                    }
                }
            }
        ).reportHeight(to: self))
    }

    @MainActor
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
        ).reportHeight(to: self))
    }

    @MainActor
    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
        ).reportHeight(to: self))
    }

    @MainActor
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
        ).reportHeight(to: self))
    }

    @MainActor
    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            store: observable
        ).reportHeight(to: self))
    }

    @MainActor
    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
        ).reportHeight(to: self))
    }

    @MainActor
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

    /// Swaps rootView. Height self-corrects automatically via didUpdateHeight()
    /// after SwiftUI renders the new content — no manual sizing needed.
    /// ❌ NEVER call this from a timer, onChange, or any polling path.
    private func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - Panel show/hide

    @MainActor @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.closePanel() } else { openPanel() }
    }

    /// Opens the panel below the status bar button.
    /// positionBelow() is called ONCE here — never again until next open.
    /// didUpdateHeight() resizes in-place without re-positioning.
    /// ❌ NEVER replace openPanelView() with mainView() here.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    @MainActor
    private func openPanel() {
        guard let button = statusItem?.button,
              button.window != nil,
              let panel,
              let hc = hostingController
        else { return }

        panelIsOpen = true
        hc.rootView = openPanelView()
        observable.reload()

        if let saved = savedNavState,
           let restored = validatedView(for: saved) {
            hc.rootView = restored
        }

        // Use 300 as a safe initial height — HeightReporter will fire the real
        // height within the same run loop and panel.updateHeight() corrects it.
        panel.positionBelow(button: button, contentHeight: 300)
    }
}
// swiftlint:enable type_body_length
