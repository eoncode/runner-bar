import AppKit
import Combine
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
//      y (frame origin) = max(visibleFrame.minY, panelTopY - totalH) ← clamped
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
// resizeAndRepositionPanel() clamps to [minWidth..maxWidth] and re-centres
// the panel under the status button.
//
// INITIAL WIDTH (openPanel):
// initPanelWidth is the fallback frame width used for the initial open before
// SwiftUI has measured anything. 320 is a compact default.
// ❌ NEVER set initPanelWidth > maxWidth.
// ❌ NEVER restore initPanelWidth to 600.
//
// POPOVEROPENSTATE:
// popoverOpenState.isOpen mirrors panelIsOpen. Injected via wrapEnv().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// ❌ NEVER pass as a plain Bool prop to PopoverMainView.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Represents the currently visible navigation screen.
///
/// #455: Removed .jobDetail, .actionDetail, .actionJobDetail, .actionStepLog.
/// Navigation from the main view now goes directly: inline step tap → .stepLog.
private enum NavState {
    /// The root popover showing runners and the recent-actions list.
    case main
    /// The raw log for a single step, reached from the main inline step row.
    case stepLog(ActiveJob, JobStep)
    /// The Settings sheet.
    case settings
    /// Runner detail drill-down reached from SettingsView runner row tap. (#491)
    case runnerDetail(RunnerModel)
    /// Scope detail drill-down reached from SettingsView scope row tap. (#499)
    case scopeDetail(ScopeEntry)
}

// MARK: - KeyablePanel

// ⚠️ TEXT INPUT FIX (#525) — DO NOT REMOVE THIS CLASS.
//
// WHY THIS EXISTS:
// NSPanel with .nonactivatingPanel overrides canBecomeKey to return false.
// This is the AppKit contract: a non-activating panel intentionally never
// steals focus from the frontmost application.
// The side-effect is that NSTextField (and SwiftUI TextField backed by it)
// never receives first-responder, making all text fields silently non-editable.
//
// FIX:
// KeyablePanel is a minimal NSPanel subclass. It adds a single `wantsKey`
// flag. canBecomeKey returns true only when `wantsKey == true`, so the panel
// only becomes key for views that contain TextFields (settings, runner detail,
// scope detail). All read-only views leave wantsKey = false, preserving the
// non-activating behaviour everywhere else.
//
// USAGE IN AppDelegate:
//   panel.wantsKey = true   — before navigating to a text-input view
//   panel.makeKeyAndOrderFront(nil) — promotes panel to key window
//   panel.wantsKey = false  — in closePanel(), resets for next open
//
// ❌ NEVER replace KeyablePanel with plain NSPanel — text fields break again.
// ❌ NEVER set wantsKey = true globally — that makes the panel steal focus
//    from the frontmost app whenever it is shown, defeating .nonactivatingPanel.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
private final class KeyablePanel: NSPanel {
    /// Set to true immediately before navigating to a view that contains TextFields.
    /// Reset to false in closePanel().
    var wantsKey = false

    override var canBecomeKey: Bool { wantsKey }
}

// MARK: - AppDelegate

// ⚠️ @MainActor ISOLATION CONTRACT — DO NOT REMOVE THIS ANNOTATION.
// AppDelegate runs entirely on the main thread. @MainActor gives the Swift 6
// compiler static proof of this so every method and stored property is verified
// as main-thread-only without any runtime assertion.
//
// The nonisolated blocking helper (enrichStepsIfNeeded) is intentionally exempt
// — it performs blocking network I/O and is always dispatched onto
// DispatchQueue.global() by its caller. nonisolated opts it out of the
// class-level @MainActor domain.
//
// ❌ NEVER remove @MainActor from this class declaration.
// ❌ NEVER remove `nonisolated` from enrichStepsIfNeeded.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var chrome: PanelChromeView?
    private var hostingController: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()
    private var savedNavState: NavState?
    private var panelIsOpen = false

    private var eventMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var workspaceObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Top anchor (screen coords) captured once in openPanel().
    /// ❌ NEVER re-derive inside resizeAndRepositionPanel().
    private var panelTopY: CGFloat?

    // ⚠️ REGRESSION GUARD (ref #377):
    // ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    // ❌ NEVER pass as a plain Bool prop to PopoverMainView.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    // ALLOWED UNDER ANY CIRCUMSTANCE.
    private let popoverOpenState = PopoverOpenState()

    /// Lower bound for panel content width (clamp floor in resizeAndRepositionPanel).
    private static let minWidth: CGFloat = 280

    /// The screen the status item lives on.
    private var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var maxWidth: CGFloat {
        let screenMax = statusItemScreen.visibleFrame.width * 0.9
        return min(900, screenMax)
    }

    private var maxHeight: CGFloat {
        statusItemScreen.visibleFrame.height * 0.85
    }

    private static let gap: CGFloat = 2

    /// Initial panel width used before SwiftUI has measured content.
    private static let initPanelWidth: CGFloat = 320

    // MARK: - Environment injection

    /// ❌ NEVER bypass. ❌ NEVER remove .environmentObject(popoverOpenState).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
    /// ALLOWED UNDER ANY CIRCUMSTANCE.
    private func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view.environmentObject(popoverOpenState))
    }

    // MARK: - Status icon helpers

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

        let newPanel = KeyablePanel(
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

        LocalRunnerStore.shared.$runners
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
            }
            .store(in: &cancellables)

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onChange fired — panelIsOpen=\(self.panelIsOpen) actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count)")
            self.updateStatusIcon()
            self.observable.reload(localRunnerStore: LocalRunnerStore.shared)
        }
        RunnerStore.shared.start()
    }

    // MARK: - OAuth URL callback (#326)
    //
    // Handles the runnerbar://oauth/callback?code=... redirect from GitHub after
    // the user authorizes the app in the browser. Forwards to OAuthService which
    // exchanges the code for a token and saves it to Keychain.
    //
    // OAuthService.onCompletion is wired in SettingsView so the Account section
    // updates automatically once the token arrives.

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              url.scheme == "runnerbar",
              url.host == "oauth"
        else { return }
        OAuthService.shared.handleCallback(url)
    }

    // MARK: - Status icon

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
        let rawPosY = topY - totalH
        let screenMinY = statusItemScreen.visibleFrame.minY
        let posY = max(rawPosY, screenMinY)

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

    // MARK: - Make key for text input

    // See KeyablePanel comment block above for the full explanation.
    // ❌ NEVER call this for views that have no text input (main, step log).
    private func makeKeyForTextInput() {
        panel?.wantsKey = true
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dismiss

    func closePanel() {
        guard panelIsOpen else { return }
        panel?.wantsKey = false
        panel?.orderOut(nil)
        panelIsOpen = false
        panelTopY = nil
        popoverOpenState.isOpen = false
        removeEventMonitor()
        removeWorkspaceObserver()
        // ⚠️ NAV STATE PERSISTENCE (#385) — DO NOT REMOVE THIS COMMENT.
        // Capture savedNavState before calling mainView() (which resets it),
        // then restore it so openPanel()'s validatedView path works.
        // ❌ NEVER replace this with a no-op stub PopoverMainView.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE.
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

    // MARK: - Enrichment helper

    nonisolated private func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
    }

    // MARK: - View factories

    private func mainView() -> AnyView {
        savedNavState = nil
        return wrapEnv(PopoverMainView(
            store: observable,
            onSelectJob: { _ in
                // Retained for ABI compatibility; navigation removed in #455.
            },
            onSelectAction: { _ in
                // Retained for ABI compatibility; navigation removed in #455.
            },
            onStepTap: { [weak self] job, step in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.stepLogFromMain(job: enriched, step: step))
                    }
                }
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    /// #455: Step tapped from inline job row on the main screen.
    /// Back button returns to mainView().
    private func stepLogFromMain(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return wrapEnv(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onLogLoaded: nil
        ))
    }

    private func settingsView() -> AnyView {
        savedNavState = .settings
        makeKeyForTextInput()
        return wrapEnv(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onSelectRunner: { [weak self] runner in
                guard let self else { return }
                self.navigate(to: self.runnerDetailView(runner: runner))
            },
            onSelectScope: { [weak self] entry in
                guard let self else { return }
                self.navigate(to: self.scopeDetailView(entry: entry))
            },
            store: observable
        ))
    }

    /// #491: RunnerDetailView drill-down from SettingsView runner row.
    private func runnerDetailView(runner: RunnerModel) -> AnyView {
        savedNavState = .runnerDetail(runner)
        makeKeyForTextInput()
        return wrapEnv(RunnerDetailView(
            runner: runner,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    /// #499: ScopeDetailView drill-down from SettingsView scope row tap.
    private func scopeDetailView(entry: ScopeEntry) -> AnyView {
        savedNavState = .scopeDetail(entry)
        makeKeyForTextInput()
        let live = ScopeStore.shared.entries.first(where: { $0.id == entry.id }) ?? entry
        return wrapEnv(ScopeDetailView(
            scopeEntry: live,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    private func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil
        let store = RunnerStore.shared
        switch state {
        case .main:
            return nil
        case .stepLog(let job, let step):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return stepLogFromMain(job: live, step: step)
        case .settings:
            return settingsView()
        case .runnerDetail(let runner):
            let live = LocalRunnerStore.shared.runners.first(where: { $0.id == runner.id }) ?? runner
            return runnerDetailView(runner: live)
        case .scopeDetail(let entry):
            guard let live = ScopeStore.shared.entries.first(where: { $0.id == entry.id }) else {
                return settingsView()
            }
            return scopeDetailView(entry: live)
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

    func openPanel() {
        guard let button = statusItem?.button,
              let statusItemRect = button.window?.frame,
              let panel else { return }

        log("AppDelegate › openPanel — seeding observable: actions=\(RunnerStore.shared.actions.count) jobs=\(RunnerStore.shared.jobs.count) localRunners=\(LocalRunnerStore.shared.runners.count)")
        observable.reload(localRunnerStore: LocalRunnerStore.shared)

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
                Task { @MainActor [weak self] in self?.closePanel() }
            }
        }
    }
}
// swiftlint:enable type_body_length
