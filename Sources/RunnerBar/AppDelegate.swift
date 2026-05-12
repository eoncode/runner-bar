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
// SIZING STRATEGY:
//   openPanel() calls hc.sizeThatFits(in: NSSize(width: fixedWidth, height: .greatestFiniteMagnitude))
//   BEFORE positionBelow() to get the real content height synchronously.
//   positionBelow() is NEVER called with a placeholder/hardcoded height.
//   didUpdateHeight() still handles live resize after navigation or data load.
//
// CONTRACT (DO NOT VIOLATE ANY RULE):
//   ✅ AppDelegate conforms to HeightReceiver.
//   ✅ Every view factory ends with .reportHeight(to: self).
//   ✅ openPanel() measures real height THEN calls panel.positionBelow().
//   ❌ NEVER pass a hardcoded height to positionBelow() — causes wrong initial size.
//   ❌ NEVER reintroduce NSPopover — the jump cannot be fixed.
//   ❌ NEVER replace HeightPreferenceKey with fittingSize — unreliable pre-layout.
//   ❌ NEVER call positionBelow() from didUpdateHeight() — re-anchors every resize.
//
// CPU GUARD (ref #375 #376 #377):
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
// ⚠️ NO class-level @MainActor — main.swift constructs AppDelegate synchronously
// in a nonisolated context (let delegate = AppDelegate()). A class-level
// @MainActor would make that call illegal. Instead every method that touches
// UI is individually annotated @MainActor or dispatched via DispatchQueue.main.
// @unchecked Sendable: AppDelegate is only ever used from main thread in practice;
// the checker cannot verify this statically because we dropped class-level @MainActor.

final class AppDelegate: NSObject, NSApplicationDelegate, HeightReceiver, @unchecked Sendable {

    // Fixed canvas width — PanelChrome and all views use this.
    static let fixedWidth: CGFloat = 420

    private var statusItem: NSStatusItem?
    private(set) var panel: PanelChrome?
    private var hostingController: NSHostingController<AnyView>?
    // Offscreen window used to give hostingController.view a real layout
    // context before the panel is shown for the first time.
    private var offscreenWindow: NSWindow?
    private lazy var observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false

    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.85
    }

    // MARK: - HeightReceiver
    nonisolated func didUpdateHeight(_ height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.panelIsOpen,
                  let panel = self.panel,
                  panel.isVisible,
                  height > 0 else { return }
            let clamped = min(height, self.maxContentHeight)
            panel.updateHeight(clamped)
        }
    }

    // MARK: - App lifecycle

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.setupUI()
        }
    }

    @MainActor
    private func setupUI() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = []
        controller.view.frame = NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 10)
        hostingController = controller

        let offWin = NSWindow(contentRect: NSRect(x: -10000, y: -10000,
                                                   width: Self.fixedWidth, height: 10),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        offWin.isReleasedWhenClosed = false
        offWin.contentView = controller.view
        offWin.orderBack(nil)
        offscreenWindow = offWin

        let chrome = PanelChrome()
        chrome.onClose = { [weak self] in
            DispatchQueue.main.async { self?.panelDidClose() }
        }
        panel = chrome

        RunnerStore.shared.onChange = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
                if !self.panelIsOpen { self.observable.reload() }
            }
        }
        RunnerStore.shared.start()
    }

    @MainActor
    private func panelDidClose() {
        panelIsOpen = false
    }

    // MARK: - View factories

    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
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
                guard let self = self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.detailView(job: enriched))
                    }
                }
            },
            onSelectAction: { [weak self] group in
                guard let self = self else { return }
                let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                DispatchQueue.main.async { self.navigate(to: self.actionDetailView(group: latest)) }
            },
            onSelectSettings: { [weak self] in
                guard let self = self else { return }
                // ⚠️ async: defer past SwiftUI body pass to prevent re-entrant rootView drop.
                // ❌ NEVER make synchronous.
                DispatchQueue.main.async { self.navigate(to: self.settingsView()) }
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
                guard let self = self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.detailView(job: enriched))
                    }
                }
            },
            onSelectAction: { [weak self] group in
                guard let self = self else { return }
                let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
                DispatchQueue.main.async { self.navigate(to: self.actionDetailView(group: latest)) }
            },
            onSelectSettings: { [weak self] in
                guard let self = self else { return }
                // ⚠️ async: same reason as mainView().
                // ❌ NEVER make synchronous.
                DispatchQueue.main.async { self.navigate(to: self.settingsView()) }
            },
            // ⚠️ CRITICAL: literal true — CPU guard.
            // ❌ NEVER change to panelIsOpen here.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE.
            isPopoverOpen: true
        ).reportHeight(to: self))
    }

    @MainActor
    private func actionDetailView(group: ActionGroup) -> AnyView {
        savedNavState = .actionDetail(group)
        return AnyView(ActionDetailView(
            group: group,
            onBack: { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.mainView()) }
            },
            onSelectJob: { [weak self] job in
                guard let self = self else { return }
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
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.actionDetailView(group: group)) }
            },
            onSelectStep: { [weak self] step in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.navigate(to: self.logViewFromAction(job: job, step: step, group: group))
                }
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
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.navigate(to: self.detailViewFromAction(job: job, group: group))
                }
            }
        ).reportHeight(to: self))
    }

    @MainActor
    private func detailView(job: ActiveJob) -> AnyView {
        savedNavState = .jobDetail(job)
        return AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.mainView()) }
            },
            onSelectStep: { [weak self] step in
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.logView(job: job, step: step)) }
            }
        ).reportHeight(to: self))
    }

    @MainActor
    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.mainView()) }
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
                guard let self = self else { return }
                DispatchQueue.main.async { self.navigate(to: self.detailView(job: job)) }
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

    /// Swaps rootView, forces AppKit layout, then resizes the panel.
    /// ⚠️ Always called via DispatchQueue.main.async from SwiftUI closures to
    ///    prevent re-entrant rootView mutation during a SwiftUI body pass.
    /// ❌ NEVER call synchronously from a SwiftUI button action / body pass.
    @MainActor
    private func navigate(to view: AnyView) {
        guard let hc = hostingController, let panel = panel else { return }

        // 1. Swap the view.
        hc.rootView = view

        // 2. ⚠️ NUCLEAR: force a full AppKit layout pass on the hosting view
        //    so the new SwiftUI tree is committed before we measure.
        //    Without this, sizeThatFits may return the OLD view's height when
        //    the new view happens to start with the same ideal size (e.g.
        //    SettingsView.cappedHeight == current panel height).
        hc.view.needsLayout = true
        hc.view.layoutSubtreeIfNeeded()

        // 3. Measure the new content.
        let size = hc.sizeThatFits(in: NSSize(width: Self.fixedWidth,
                                               height: .greatestFiniteMagnitude))
        let clamped = min(size.height, maxContentHeight)

        // 4. Resize panel. forceLayout:true bypasses the kHeightEpsilon guard
        //    so the panel always re-frames on navigation even if height is equal.
        if clamped >= 50 { panel.updateHeight(clamped, force: true) }
    }

    // MARK: - Panel show/hide

    @MainActor @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.closePanel() } else { openPanel() }
    }

    /// Opens the panel with the REAL measured height. positionBelow() called once per open.
    /// ❌ NEVER replace openPanelView() with mainView() here.
    /// ❌ NEVER pass a hardcoded height to positionBelow().
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

        let stateToRestore = savedNavState

        offscreenWindow?.contentView = nil
        panel.hostingView = hc.view

        hc.rootView = openPanelView()

        if let saved = stateToRestore,
           let restored = validatedView(for: saved) {
            hc.rootView = restored
        }

        panel.contentView?.layoutSubtreeIfNeeded()

        let measured = hc.sizeThatFits(
            in: NSSize(width: Self.fixedWidth,
                       height: .greatestFiniteMagnitude)
        )
        let contentHeight = min(max(measured.height, 100), maxContentHeight)
        panel.positionBelow(button: button, contentHeight: contentHeight)

        // ⚠️ RELOAD GUARD: only reload when restoring a saved nav state.
        if stateToRestore != nil {
            observable.reload()
        }
    }
}
// swiftlint:enable type_body_length
