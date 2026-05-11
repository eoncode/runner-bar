import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #377 #379 #380)
//
// ARCHITECTURE: Architecture 3 — NSPanel (borderless, non-activating) with
//   NSVisualEffectView + CAShapeLayer mask for rounded corners and popover arrow.
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
//   UNDER ANY CIRCUMSTANCE.
//
// PANEL SETUP — ALL must hold simultaneously:
//   styleMask = [.borderless, .nonactivatingPanel]
//   isFloatingPanel = true
//   level = .popUpMenu
//   collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
//   hidesOnDeactivate = false  ← MUST be false on a nonactivatingPanel.
//   isOpaque = false, backgroundColor = .clear
//     ← MUST be transparent so NSVisualEffectView + clipping mask shows.
//   hasShadow = false  ← shadow is applied to the visualEffectView layer instead.
//
// VISUAL EFFECT VIEW:
//   NSVisualEffectView is the content view. It provides the frosted glass material.
//   A CAShapeLayer mask clips it to rounded rect + arrow shape.
//   Shadow is drawn by a shadow CALayer behind the visualEffectView.
//
// POSITIONING:
//   showPanel() computes origin via button.convert(button.bounds, to: nil) then
//   buttonWindow.convertToScreen(_:). The panel frame includes arrowHeight (9pt)
//   extra at top so the arrow tip is within the panel frame.
//   ❌ NEVER use button.frame directly in convertToScreen — button.frame is in
//   superview space, not window space.
//
// RESIZING (while shown):
//   resizePanel(to:) keeps topLeft (panel.frame.maxY) fixed, grows downward.
//   ❌ NEVER use setFrameSize — anchors from bottom-left, shifts panel up.
//
// ❌ NEVER add an NSPopover back.
// ❌ NEVER remove HeightPreferenceKey wiring from PopoverMainView.
// ❌ NEVER remove .onPreferenceChange(HeightPreferenceKey.self) from wrapWithHeightCapture.
// ❌ NEVER remove @MainActor from AppDelegate.
// ❌ NEVER remove nonisolated from enrichStepsIfNeeded / enrichGroupIfNeeded.
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
    private var visualEffectView: NSVisualEffectView?
    private var maskLayer: CAShapeLayer?
    private var shadowLayer: CALayer?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false
    private var mouseMonitor: Any?

    /// X offset of the arrow tip relative to panel left edge. Set each open.
    private var arrowTipX: CGFloat = 210

    /// Last height reported by HeightPreferenceKey (content only, not including arrowHeight).
    /// ❌ NEVER read before the first onPreferenceChange fires after showPanel().
    private var measuredHeight: CGFloat = 300

    private static let canonicalWidth: CGFloat = 420
    private static let maxHeight: CGFloat = 620
    private static let minHeight: CGFloat = 120
    private static let statusBarGap: CGFloat = 2
    /// Height of the upward-pointing arrow (notch at the top of the panel).
    private static let arrowHeight: CGFloat = 9
    /// Half-width of the arrow base.
    private static let arrowHalfWidth: CGFloat = 10
    /// Corner radius matching system NSPopover.
    private static let cornerRadius: CGFloat = 12

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

    /// Builds the NSPanel, NSVisualEffectView, and NSHostingView once at launch.
    /// ❌ NEVER call more than once — panel is reused across open/close cycles.
    private func buildPanel() {
        let totalHeight = measuredHeight + Self.arrowHeight
        let initialSize = NSSize(width: Self.canonicalWidth, height: totalHeight)

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
        // ❌ NEVER set this to true.
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        // ⚠️ Panel must be transparent so the VFX view + clipping mask shows.
        // ❌ NEVER set isOpaque = true here.
        p.isOpaque = false
        p.backgroundColor = .clear
        // ⚠️ Shadow is rendered by shadowLayer on the VFX view, not by NSPanel.
        p.hasShadow = false

        // Shadow layer drawn behind the VFX view
        let shadow = CALayer()
        shadow.frame = NSRect(origin: .zero, size: initialSize)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        shadow.shadowRadius = 20
        shadow.shadowOpacity = 1
        shadow.backgroundColor = NSColor.clear.cgColor
        shadowLayer = shadow

        // Visual effect view — frosted glass, fills panel
        let vfx = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialSize))
        vfx.material = .menu
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.autoresizingMask = [.width, .height]
        visualEffectView = vfx

        // Install shadow behind VFX
        vfx.layer?.insertSublayer(shadow, at: 0)

        // Hosting view inside the VFX view, offset by arrowHeight
        let contentHeight = measuredHeight
        let contentFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.canonicalWidth,
            height: contentHeight
        )
        let rootView = wrapWithHeightCapture(mainView())
        let hv = NSHostingView(rootView: rootView)
        hv.frame = contentFrame
        hv.autoresizingMask = [.width, .minYMargin]
        vfx.addSubview(hv)
        hostingView = hv

        p.contentView = vfx
        panel = p

        // Apply initial mask (will be updated each open with correct arrowTipX)
        applyMask(panelSize: initialSize)
    }

    // MARK: - Shape mask (rounded rect + upward arrow)

    /// Applies a CAShapeLayer mask to the visualEffectView clipping it to a
    /// rounded rectangle with an upward-pointing arrow notch at the top.
    ///
    /// The arrow tip sits at (arrowTipX, panelHeight - 1) in the VFX view's
    /// coordinate system (AppKit: origin at bottom-left, so top = maxY).
    ///
    /// The panel frame includes arrowHeight extra height at the top, so the
    /// content rect begins at y=0 and the arrow occupies
    /// y=(panelHeight - arrowHeight)..y=panelHeight.
    private func applyMask(panelSize: NSSize) {
        guard let vfx = visualEffectView else { return }

        let w = panelSize.width
        let h = panelSize.height
        let r = Self.cornerRadius
        let ah = Self.arrowHeight
        let ahw = Self.arrowHalfWidth
        let ax = max(r + ahw + 4, min(arrowTipX, w - r - ahw - 4))

        // Build path in AppKit coords (origin bottom-left, y increases upward).
        // The body rect spans from y=0 to y=(h - ah).
        // The arrow protrudes from y=(h - ah) to y=h.
        let bodyTop = h - ah

        let path = CGMutablePath()
        // Start at bottom-left corner arc
        path.move(to: CGPoint(x: r, y: 0))
        // Bottom edge → bottom-right
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        // Right edge → top-right of body
        path.addLine(to: CGPoint(x: w, y: bodyTop - r))
        path.addArc(center: CGPoint(x: w - r, y: bodyTop - r), radius: r,
                    startAngle: 0, endAngle: .pi / 2, clockwise: false)
        // Top edge right-side, up to arrow base right
        path.addLine(to: CGPoint(x: ax + ahw, y: bodyTop))
        // Arrow: right base → tip → left base
        path.addLine(to: CGPoint(x: ax, y: h))
        path.addLine(to: CGPoint(x: ax - ahw, y: bodyTop))
        // Top edge left-side
        path.addLine(to: CGPoint(x: r, y: bodyTop))
        path.addArc(center: CGPoint(x: r, y: bodyTop - r), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        // Left edge → bottom-left
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        path.closeSubpath()

        let mask = CAShapeLayer()
        mask.path = path
        vfx.layer?.mask = mask
        maskLayer = mask

        // Update shadow layer path too
        if let shadowLayer {
            shadowLayer.frame = CGRect(origin: .zero, size: panelSize)
            let shadowMask = CAShapeLayer()
            shadowMask.path = path
            shadowLayer.shadowPath = path
        }
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
    /// Total panel height = content height + arrowHeight.
    /// ❌ NEVER use setFrameSize — anchors from bottom-left and shifts panel up.
    /// ❌ NEVER change the x origin.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    private func resizePanel(to rawContentHeight: CGFloat) {
        guard let panel, let vfx = visualEffectView, let hv = hostingView else { return }
        let contentH = min(max(rawContentHeight, Self.minHeight), Self.maxHeight)
        let totalH = contentH + Self.arrowHeight
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let newFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - totalH,
            width: Self.canonicalWidth,
            height: totalH
        )
        panel.setFrame(newFrame, display: true, animate: false)
        vfx.frame = NSRect(origin: .zero, size: newFrame.size)
        // Hosting view stays at bottom, grows up
        hv.frame = NSRect(x: 0, y: 0, width: Self.canonicalWidth, height: contentH)
        applyMask(panelSize: newFrame.size)
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
    /// Panel frame includes arrowHeight extra at the top so the arrow tip
    /// aligns visually with the status bar button.
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

        let contentH = min(max(measuredHeight, Self.minHeight), Self.maxHeight)
        let totalH = contentH + Self.arrowHeight
        let width = Self.canonicalWidth

        var originX = buttonScreenRect.midX - width / 2
        if let screen = NSScreen.main {
            let maxX = screen.visibleFrame.maxX - width
            originX = min(originX, maxX)
            originX = max(originX, screen.visibleFrame.minX)
        }
        // Arrow tip X relative to panel left edge
        arrowTipX = buttonScreenRect.midX - originX

        // Panel origin: top of panel aligns with bottom of status bar button
        // (minY of button rect in screen coords), panel grows downward.
        let originY = buttonScreenRect.minY - totalH - Self.statusBarGap

        let frame = NSRect(x: originX, y: originY, width: width, height: totalH)
        panel.setFrame(frame, display: false)

        // Size the VFX view and hosting view to match
        visualEffectView?.frame = NSRect(origin: .zero, size: frame.size)
        hostingView?.frame = NSRect(x: 0, y: 0, width: width, height: contentH)
        applyMask(panelSize: frame.size)

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
