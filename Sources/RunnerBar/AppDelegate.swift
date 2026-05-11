import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - NavState

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #59 #296 #377 #379 #380)
//
// ARCHITECTURE: Architecture 3 — NSPanel (borderless, non-activating) with
//   NSVisualEffectView + CAShapeLayer mask for rounded corners and popover arrow.
//
// HEIGHT MECHANISM:
//   PopoverMainView reports its rendered height via HeightPreferenceKey.
//   AppDelegate reads this in .onPreferenceChange and calls resizePanel(to:).
//   resizePanel repositions the panel keeping the TOP-LEFT corner fixed.
//
//   KEY INVARIANT: hostingView has a large sentinel height (4000pt) so SwiftUI
//   is never height-constrained and GeometryReader reports real content height.
//   hostingView.frame.origin.y = visibleHeight - sentinelHeight  (large negative)
//   This aligns the hostingView's TOP edge with the VFX view's TOP edge so
//   SwiftUI content is visible at the top of the panel.
//
//   ❌ NEVER give NSHostingView a fixed height equal to contentH.
//   ❌ NEVER set hostingView origin.y = 0 when using sentinel height.
//   ❌ NEVER use fittingSize.
//   ❌ NEVER remove HeightPreferenceKey machinery.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT.
//
// PANEL SETUP:
//   styleMask = [.borderless, .nonactivatingPanel]
//   isFloatingPanel = true, level = .popUpMenu
//   collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
//   hidesOnDeactivate = false
//   isOpaque = false, backgroundColor = .clear, hasShadow = false
//
// ❌ NEVER add NSPopover back.
// ❌ NEVER remove @MainActor from AppDelegate.
// ❌ NEVER remove nonisolated from enrich* methods.
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

final class RunnerBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

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
    private var arrowTipX: CGFloat = 210
    /// Last measured content height from HeightPreferenceKey.
    private var measuredHeight: CGFloat = 120

    private static let canonicalWidth: CGFloat = 420
    private static let maxHeight: CGFloat = 620
    private static let minHeight: CGFloat = 120
    private static let statusBarGap: CGFloat = 2
    private static let arrowHeight: CGFloat = 9
    private static let arrowHalfWidth: CGFloat = 10
    private static let cornerRadius: CGFloat = 12
    /// Sentinel: large enough that SwiftUI never hits a height constraint.
    /// hostingView.origin.y = visibleHeight - sentinel  (keeps top edges aligned).
    private static let sentinelHeight: CGFloat = 4000

    // MARK: - Lifecycle

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
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: - Build

    private func buildPanel() {
        let initialTotalH = Self.minHeight + Self.arrowHeight
        let initialSize = NSSize(width: Self.canonicalWidth, height: initialTotalH)

        let p = RunnerBarPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false

        let shadow = CALayer()
        shadow.frame = NSRect(origin: .zero, size: initialSize)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        shadow.shadowRadius = 20
        shadow.shadowOpacity = 1
        shadow.backgroundColor = NSColor.clear.cgColor
        shadowLayer = shadow

        let vfx = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialSize))
        vfx.material = .menu
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.autoresizingMask = [.width, .height]
        visualEffectView = vfx
        vfx.layer?.insertSublayer(shadow, at: 0)

        // Sentinel height: SwiftUI is unconstrained vertically.
        // Origin Y is set so the hosting view's TOP aligns with the VFX view's TOP.
        // In AppKit coords (y=0 at bottom): originY = totalH - sentinelHeight.
        let originY = initialTotalH - Self.sentinelHeight
        let hv = NSHostingView(rootView: wrapWithHeightCapture(mainView()))
        hv.sizingOptions = []
        hv.autoresizingMask = [.width]
        hv.frame = NSRect(x: 0, y: originY, width: Self.canonicalWidth, height: Self.sentinelHeight)
        vfx.addSubview(hv)
        hostingView = hv

        p.contentView = vfx
        panel = p
        applyMask(panelSize: initialSize)
    }

    // MARK: - Mask

    private func applyMask(panelSize: NSSize) {
        guard let vfx = visualEffectView else { return }
        let w = panelSize.width
        let h = panelSize.height
        let r = Self.cornerRadius
        let ah = Self.arrowHeight
        let ahw = Self.arrowHalfWidth
        let ax = max(r + ahw + 4, min(arrowTipX, w - r - ahw - 4))
        let bodyTop = h - ah

        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        path.addLine(to: CGPoint(x: w, y: bodyTop - r))
        path.addArc(center: CGPoint(x: w - r, y: bodyTop - r), radius: r,
                    startAngle: 0, endAngle: .pi / 2, clockwise: false)
        path.addLine(to: CGPoint(x: ax + ahw, y: bodyTop))
        path.addLine(to: CGPoint(x: ax, y: h))
        path.addLine(to: CGPoint(x: ax - ahw, y: bodyTop))
        path.addLine(to: CGPoint(x: r, y: bodyTop))
        path.addArc(center: CGPoint(x: r, y: bodyTop - r), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        path.closeSubpath()

        let mask = CAShapeLayer()
        mask.path = path
        vfx.layer?.mask = mask
        maskLayer = mask

        if let shadowLayer {
            shadowLayer.frame = CGRect(origin: .zero, size: panelSize)
            shadowLayer.shadowPath = path
        }
    }

    // MARK: - Height capture

    private func wrapWithHeightCapture(_ view: AnyView) -> AnyView {
        AnyView(
            view.onPreferenceChange(HeightPreferenceKey.self) { [weak self] height in
                guard let self, height > 0 else { return }
                self.measuredHeight = height
                if self.panelIsOpen {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.panelIsOpen else { return }
                        self.resizePanel(to: height)
                    }
                }
            }
        )
    }

    // MARK: - Resize

    private func resizePanel(to rawContentHeight: CGFloat) {
        guard let panel, let vfx = visualEffectView, let hv = hostingView else { return }
        let contentH = min(max(rawContentHeight, Self.minHeight), Self.maxHeight)
        let totalH = contentH + Self.arrowHeight
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - totalH,
                              width: Self.canonicalWidth, height: totalH)
        panel.setFrame(newFrame, display: true, animate: false)
        vfx.frame = NSRect(origin: .zero, size: newFrame.size)
        // Keep top edges aligned: originY = totalH - sentinelHeight
        hv.frame = NSRect(x: 0, y: totalH - Self.sentinelHeight,
                          width: Self.canonicalWidth, height: Self.sentinelHeight)
        applyMask(panelSize: newFrame.size)
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
            onBack: { [weak self] in self?.navigate(to: self?.mainView() ?? AnyView(EmptyView())) },
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
            onBack: { [weak self] in self?.navigate(to: self?.actionDetailView(group: group) ?? AnyView(EmptyView())) },
            onSelectStep: { [weak self] step in
                self?.navigate(to: self?.logViewFromAction(job: job, step: step, group: group) ?? AnyView(EmptyView()))
            }
        ).frame(width: Self.canonicalWidth))
    }

    private func logViewFromAction(job: ActiveJob, step: JobStep, group: ActionGroup) -> AnyView {
        savedNavState = .actionStepLog(job, step, group)
        return AnyView(StepLogView(
            job: job, step: step,
            onBack: { [weak self] in self?.navigate(to: self?.detailViewFromAction(job: job, group: group) ?? AnyView(EmptyView())) }
        ).frame(width: Self.canonicalWidth))
    }

    private func detailView(job: ActiveJob) -> AnyView {
        savedNavState = .jobDetail(job)
        return AnyView(JobDetailView(
            job: job,
            onBack: { [weak self] in self?.navigate(to: self?.mainView() ?? AnyView(EmptyView())) },
            onSelectStep: { [weak self] step in
                self?.navigate(to: self?.logView(job: job, step: step) ?? AnyView(EmptyView()))
            }
        ).frame(width: Self.canonicalWidth))
    }

    private func settingsView() -> AnyView {
        savedNavState = .settings
        return AnyView(SettingsView(
            onBack: { [weak self] in self?.navigate(to: self?.mainView() ?? AnyView(EmptyView())) },
            store: observable
        ).frame(width: Self.canonicalWidth))
    }

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return AnyView(StepLogView(
            job: job, step: step,
            onBack: { [weak self] in self?.navigate(to: self?.detailView(job: job) ?? AnyView(EmptyView())) }
        ).frame(width: Self.canonicalWidth))
    }

    private func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil
        let store = RunnerStore.shared
        switch state {
        case .main: return nil
        case .jobDetail(let job):
            return detailView(job: store.jobs.first(where: { $0.id == job.id }) ?? job)
        case .stepLog(let job, let step):
            return logView(job: store.jobs.first(where: { $0.id == job.id }) ?? job, step: step)
        case .actionDetail(let group):
            guard let live = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return actionDetailView(group: live)
        case .actionJobDetail(let job, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return detailViewFromAction(job: liveGroup.jobs.first(where: { $0.id == job.id }) ?? job, group: liveGroup)
        case .actionStepLog(let job, let step, let group):
            guard let liveGroup = store.actions.first(where: { $0.id == group.id }) else { return nil }
            return logViewFromAction(job: liveGroup.jobs.first(where: { $0.id == job.id }) ?? job, step: step, group: liveGroup)
        case .settings: return settingsView()
        }
    }

    // MARK: - Navigation

    private func navigate(to view: AnyView) {
        hostingView?.rootView = wrapWithHeightCapture(view)
    }

    // MARK: - Show / Hide

    @objc private func togglePanel() {
        panelIsOpen ? dismiss() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let panel else { return }

        panelIsOpen = true
        observable.reload()

        if let saved = savedNavState, let restored = validatedView(for: saved) {
            hostingView?.rootView = wrapWithHeightCapture(restored)
        }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonInWindow)

        let contentH = min(max(measuredHeight, Self.minHeight), Self.maxHeight)
        let totalH = contentH + Self.arrowHeight
        let width = Self.canonicalWidth

        var originX = buttonScreenRect.midX - width / 2
        if let screen = NSScreen.main {
            originX = min(originX, screen.visibleFrame.maxX - width)
            originX = max(originX, screen.visibleFrame.minX)
        }
        arrowTipX = buttonScreenRect.midX - originX

        let originY = buttonScreenRect.minY - totalH - Self.statusBarGap
        let frame = NSRect(x: originX, y: originY, width: width, height: totalH)
        panel.setFrame(frame, display: false)
        visualEffectView?.frame = NSRect(origin: .zero, size: frame.size)
        // Align hosting view top with VFX top
        hostingView?.frame = NSRect(x: 0, y: totalH - Self.sentinelHeight,
                                    width: width, height: Self.sentinelHeight)
        applyMask(panelSize: frame.size)

        panel.orderFront(nil)
        panel.makeKey()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self else { return }
            if let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

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
