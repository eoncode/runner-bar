import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ ARCHITECTURE: NSPanel (not NSPopover)
// ═══════════════════════════════════════════════════════════════════════════════
//
// NSPopover replaced after 50+ commits. Root cause: re-anchors on ANY
// contentSize change while shown. No public API override exists.
//
// HEIGHT STRATEGY: HeightPreferenceKey (not fittingSize)
//   fittingSize is unreliable before SwiftUI completes a real layout pass.
//   Instead, SwiftUI views report their rendered height via HeightReporter.swift
//   using GeometryReader + PreferenceKey. AppDelegate.didUpdateHeight() is
//   called on the main thread whenever content height changes.
//   panel.updateHeight() resizes in-place — no re-anchor possible.
//
// See: status-bar-app-position-warning.md
//      issues #52 #54 #57 #375 #376 #377 #379 #380
//
// ── NAVIGATION ───────────────────────────────────────────────────────────────
//   Level 1: PopoverMainView   — job list + runners + scopes + settings
//   Level 2: JobDetailView     — step list for a selected job
//   Level 3: StepLogView       — log output for a selected step
//
// ── ABSOLUTE NEVER LIST ─────────────────────────────────────────────────────
//   ❌ Reintroduce NSPopover — the jump cannot be fixed
//   ❌ Replace HeightPreferenceKey with fittingSize — unreliable pre-layout
//   ❌ reload() from panelDidClose — thrash loop
//   ❌ reload() before panelIsOpen = true — race with onChange
//
// ═══════════════════════════════════════════════════════════════════════════════

final class AppDelegate: NSObject, NSApplicationDelegate, HeightReceiver {

    private var statusItem: NSStatusItem?
    private(set) var panel: PanelChrome?
    private var hc: NSHostingController<AnyView>?
    private let observable = RunnerStoreObservable()

    // Guard: reload() only fires while panel is closed.
    private var panelIsOpen = false

    // Last reported rendered height from HeightPreferenceKey.
    private var lastReportedHeight: CGFloat = 0

    // Fixed canvas width. Views use .frame(idealWidth: 340, maxWidth: .infinity).
    static let fixedWidth: CGFloat = 340

    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.85
    }

    // MARK: — HeightReceiver

    func didUpdateHeight(_ height: CGFloat) {
        // Called from main thread by onPreferenceChange.
        let clamped = min(height, maxContentHeight)
        lastReportedHeight = clamped
        guard let panel, panel.isVisible else { return }
        panel.updateHeight(clamped)
    }

    // MARK: — App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusIcon(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }

        let hc = NSHostingController(rootView: mainView())
        // Give the hosting view a real width so SwiftUI can compute height.
        hc.view.frame = NSRect(origin: .zero,
                               size: NSSize(width: Self.fixedWidth, height: 10))
        self.hc = hc

        let panel = PanelChrome()
        panel.onClose = { [weak self] in self?.panelDidClose() }
        panel.hostingView = hc.view
        self.panel = panel

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image =
                makeStatusIcon(for: RunnerStore.shared.aggregateStatus)
            if !self.panelIsOpen { self.observable.reload() }
        }
        RunnerStore.shared.start()
    }

    // MARK: — Panel lifecycle

    func panelDidClose() {
        panelIsOpen = false
        lastReportedHeight = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hc?.rootView = self.mainView()
        }
    }

    // MARK: — View factories
    // Each factory wraps the view with .reportHeight(to: self) so didUpdateHeight
    // fires automatically whenever the content height changes.

    private func mainView() -> AnyView {
        AnyView(
            PopoverMainView(store: observable, onSelectJob: { [weak self] job in
                guard let self else { return }
                self.navigate(to: self.detailView(job: job))
            })
            .reportHeight(to: self)
        )
    }

    private func detailView(job: ActiveJob) -> AnyView {
        AnyView(
            JobDetailView(
                job: job,
                onBack: { [weak self] in
                    guard let self else { return }
                    self.navigate(to: self.mainView())
                },
                onSelectStep: { [weak self] step in
                    guard let self else { return }
                    self.navigate(to: self.logView(job: job, step: step))
                }
            )
            .reportHeight(to: self)
        )
    }

    private func logView(job: ActiveJob, step: JobStep) -> AnyView {
        AnyView(
            StepLogView(
                job: job,
                step: step,
                onBack: { [weak self] in
                    guard let self else { return }
                    self.navigate(to: self.detailView(job: job))
                }
            )
            .reportHeight(to: self)
        )
    }

    // MARK: — Navigation

    private func navigate(to view: AnyView) {
        // Height will arrive automatically via didUpdateHeight() after SwiftUI
        // renders the new view. No fittingSize polling needed.
        hc?.rootView = view
    }

    // MARK: — Panel show/hide

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard let button = statusItem?.button,
              button.window != nil,
              let panel, let hc else { return }

        panelIsOpen = true
        observable.reload()

        // Give SwiftUI one run-loop tick to measure, then show.
        // didUpdateHeight will have fired by then if lastReportedHeight > 0.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Use last known height if available, else let panel start at
            // a sensible default and grow when the first didUpdateHeight fires.
            let h = self.lastReportedHeight > 0 ? self.lastReportedHeight : 300
            panel.positionBelow(button: button, contentHeight: h)
            // Force a fresh layout pass — height will self-correct within
            // the same run loop via didUpdateHeight if content changed.
            hc.view.needsLayout = true
        }
    }
}
