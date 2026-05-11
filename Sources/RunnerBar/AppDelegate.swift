import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #377 #379 #380)
//
// ARCHITECTURE: Architecture 3 — NSPanel (borderless, non-activating)
// Replaces NSPopover which caused irreducible side-jump/misalignment on every open.
//
// WHY NSPanel:
//   NSPanel gives us full control of the window frame. We compute the origin once
//   from the status item button's screen rect, set it before show, never touch it again.
//   No re-anchoring. No preferredEdge weirdness. No contentSize fighting SwiftUI.
//
// HEIGHT MECHANISM:
//   PopoverMainView reports its rendered height via HeightPreferenceKey.
//   AppDelegate reads this in .onPreferenceChange and calls resizePanel(to:).
//   resizePanel repositions the panel keeping the TOP-LEFT corner fixed so the
//   panel grows downward only. ❌ NEVER use fittingSize — cached and stale.
//   ❌ NEVER remove HeightPreferenceKey or .onPreferenceChange from the view.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// PANEL SETUP — ALL must hold simultaneously:
//   styleMask = [.borderless, .nonactivatingPanel]
//   isFloatingPanel = true
//   level = .popUpMenu
//   collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
//   hidesOnDeactivate = false  ← MUST be false on a nonactivatingPanel.
//     The app never "activates" as a normal app, so hidesOnDeactivate=true would
//     hide the panel immediately on makeKey(). Mouse monitor handles dismiss instead.
//   isOpaque = true, backgroundColor = NSColor.windowBackgroundColor
//     ← MUST be opaque. A borderless panel with clear background is completely
//     invisible. The NSHostingView renders on top of this background.
//   isMovableByWindowBackground = false
//
// POSITIONING:
//   showPanel() computes origin via button.convert(button.bounds, to: nil) then
//   buttonWindow.convertToScreen(_:). This gives coordinates in screen space.
//   ❌ NEVER use button.frame directly in convertToScreen — button.frame is in
//   superview space, not window space; use button.convert(button.bounds, to: nil).
//   origin.x = buttonRect.midX - width/2 (centred on button), clamped to screen.
//   origin.y = buttonRect.minY - height - statusBarGap (panel sits below button).
//   setFrame BEFORE orderFront. Nothing moves the panel after show.
//
// RESIZING (while shown):
//   resizePanel(to:) keeps topLeft (panel.frame.maxY) fixed, grows downward.
//   ❌ NEVER use setFrameSize — anchors from bottom-left, shifts panel up.
//
// CLOSE:
//   dismiss() calls panel.orderOut(nil). Global mouse monitor handles outside clicks.
//   ❌ NEVER rely on hidesOnDeactivate for close — it does not work on nonactivatingPanel.
//
// ❌ NEVER add an NSPopover back.
// ❌ NEVER use sizingOptions — we use NSHostingView directly, no NSHostingController.
// ❌ NEVER set the panel frame after orderFront (except resizePanel).
// ❌ NEVER remove @MainActor from AppDelegate.
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded / enrichGroupIfNeeded.
// ❌ NEVER remove HeightPreferenceKey wiring from PopoverMainView.
// ❌ NEVER remove .onPreferenceChange(HeightPreferenceKey.self) from wrapWithHeightCapture.
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

// MARK: - RunnerBarPanel

/// Borderless, non-activating NSPanel used as the popover replacement.
final class RunnerBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: RunnerBarPanel?
    private var hostingView: NSHostingView<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false
    private var mouseMonitor: Any?

    /// Last height reported by HeightPreferenceKey.
    /// ❌ NEVER read before the first onPreferenceChange fires after showPanel().
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private var measuredHeight: CGFloat = 300

    private static let canonicalWidth: CGFloat = 420
    private static let maxHeight: CGFloat = 620
    private static let minHeight: CGFloat = 120
    private static let statusBarGap: CGFloat = 4

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        buildPanel()

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image = makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            // ❌ NOTHING ELSE here. No sizing. No navigate(). Fires while shown → jump.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Panel construction

    /// Builds the NSPanel and NSHostingView once at launch.
    /// ❌ NEVER call more than once — panel is reused across open/close cycles.
    private func buildPanel() {
        let initialSize = NSSize(width: Self.canonicalWidth, height: measuredHeight)

        let p = RunnerBarPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        // ⚠️ hidesOnDeactivate MUST be false on a nonactivatingPanel.
        // The app never fully "activates", so true would hide the panel on makeKey().
        // The global mouse monitor is the sole dismiss mechanism.
        // ❌ NEVER set this to true.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        // ⚠️ isOpaque MUST be true and backgroundColor must be non-clear.
        // A borderless panel with clear/transparent background renders as completely
        // invisible. NSHostingView paints on top of this background color.
        // ❌ NEVER set isOpaque = false or backgroundColor = .clear.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        p.isOpaque = true
        p.backgroundColor = NSColor.windowBackgroundColor
        p.hasShadow = true

        let rootView = wrapWithHeightCapture(mainView())
        let hv = NSHostingView(rootView: rootView)
        hv.frame = NSRect(origin: .zero, size: initialSize)
        hv.autoresizingMask = [.width, .height]
        p.contentView = hv
        hostingView = hv
        panel = p
    }

    // MARK: - Height capture

    /// Wraps any view with HeightPreferenceKey capture.
    /// When panelIsOpen, also calls resizePanel(to:) live.
    /// ❌ NEVER remove this wrapper.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func wrapWithHeightCapture(_ view: AnyView) -> AnyView {
        AnyView(
            view
                .onPreferenceChange(HeightPreferenceKey.self) { [weak self] height in
                    guard let self, height > 0 else { return }
                    self.measuredHeight = height
                    if self.panelIsOpen {
                        self.resizePanel(to: height)
                    }
                }
        )
    }

    // MARK: - Panel resizing

    /// Keeps TOP-LEFT corner fixed, grows panel downward only.
    /// ❌ NEVER use setFrameSize — anchors from bottom-left and shifts panel up.
    /// ❌ NEVER change the x origin.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func resizePanel(to rawHeight: CGFloat) {
        guard let panel else { return }
        let height = min(max(rawHeight, Self.minHeight), Self.maxHeight)
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let newFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - height,
            width: Self.canonicalWidth,
            height: height
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - View factories

    /// nonisolated: pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty
                || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    /// nonisolated: pure network I/O, no @MainActor state.
    /// ❌ NEVER remove nonisolated.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    nonisolated private func enrichGroupIfNeeded(_ group: ActionGroup) -> ActionGroup {
        guard group.jobs.isEmpty else { return group }
        let fetched = fetchActionGroups(for: group.repo)
        return fetched.first(where: { $0.id == group.id }) ?? group
    }

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
                DispatchQueue.global(qos: .userInitiated).async {
                    let latest = RunnerStore.shared.actions.first(where: { $0.id == group.id }) ?? group
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
            }
        ))
    }

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
        ).frame(width: Self.canonicalWidth))
    }

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
        ).frame(width: Self.canonicalWidth))
    }

    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailViewFromAction(job: job, group: group))
            }
        ).frame(width: Self.canonicalWidth))
    }

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
        ).frame(width: Self.canonicalWidth))
    }

    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            store: observable
        ).frame(width: Self.canonicalWidth))
    }

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            }
        ).frame(width: Self.canonicalWidth))
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

    // MARK: - Navigation

    /// Pure rootView swap. ZERO position/size changes. Forever.
    /// ❌ NEVER add frame changes here.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func navigate(to view: AnyView) {
        hostingView?.rootView = wrapWithHeightCapture(view)
    }

    // MARK: - Show / Hide

    @objc private func togglePanel() {
        if panelIsOpen {
            dismiss()
        } else {
            showPanel()
        }
    }

    /// Shows the panel anchored below the status item button.
    ///
    /// POSITIONING — three-step coordinate conversion:
    ///   1. button.convert(button.bounds, to: nil)
    ///      → converts button bounds into the button's WINDOW coordinate space.
    ///      ❌ NEVER use button.frame directly — that is in the superview's space.
    ///   2. buttonWindow.convertToScreen(_:)
    ///      → converts window coords to screen (flipped) coords.
    ///   3. origin.x = buttonRect.midX - width/2, clamped to screen edges.
    ///      origin.y = buttonRect.minY - height - statusBarGap.
    ///   4. setFrame BEFORE orderFront. Panel never moves after show.
    ///
    /// ❌ NEVER call orderFront before setFrame.
    /// ❌ NEVER move the panel after orderFront (except resizePanel).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func showPanel() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let panel
        else { return }

        panelIsOpen = true
        observable.reload()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            hostingView?.rootView = wrapWithHeightCapture(restored)
        }

        // Convert button bounds → window space → screen space
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonInWindow)

        let height = min(max(measuredHeight, Self.minHeight), Self.maxHeight)
        let width = Self.canonicalWidth

        var originX = buttonScreenRect.midX - width / 2
        if let screen = NSScreen.main {
            let maxX = screen.visibleFrame.maxX - width
            originX = min(originX, maxX)
            originX = max(originX, screen.visibleFrame.minX)
        }
        let originY = buttonScreenRect.minY - height - Self.statusBarGap

        let frame = NSRect(x: originX, y: originY, width: width, height: height)
        panel.setFrame(frame, display: false)
        panel.orderFront(nil)
        panel.makeKey()

        // Global mouse-down monitor: dismiss on click outside panel.
        // ❌ NEVER remove this — it is the sole dismiss mechanism.
        // ❌ NEVER rely on hidesOnDeactivate instead.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self else { return }
            if let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

    /// Hides the panel and resets to main view for next open.
    func dismiss() {
        panelIsOpen = false
        panel?.orderOut(nil)

        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingView?.rootView = self.wrapWithHeightCapture(self.mainView())
        }
    }
}
// swiftlint:enable type_body_length
