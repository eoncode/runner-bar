// AppDelegate+Navigation.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - AppDelegate + Navigation
//
// This file is the SINGLE SOURCE OF TRUTH for:
//   1. ALL view factories (mainView, settingsView, etc.)
//   2. ALL navigation calls (navigateToSettings, navigateBack, etc.)
//   3. NavState / validatedView(for:)
//
// ARCHITECTURE RULES:
// ❌ NEVER inline view construction in AppDelegate.swift.
// ❌ NEVER add a second navigation method elsewhere.
// ❌ NEVER call navigate(to:) from a SwiftUI view — use callbacks only.
// ❌ NEVER wrap StepLogView or SettingsView in PanelContainerView here.
//    PanelContainerView is applied ONCE at the root in mainView() only.
//    Nesting it causes multiple overlapping dim overlays → gray/black flash.

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - View factories

    /// Root view. PanelContainerView applied HERE and ONLY here.
    /// All child views navigated to via navigate(to:) are NOT wrapped in
    /// PanelContainerView — the root wrapper persists across rootView swaps
    /// because it is the outermost container, not the rootView content itself.
    ///
    /// IMPORTANT: PanelContainerView wraps only PanelMainView (the root content).
    /// When navigate(to:) swaps rootView to settingsView/stepLogView, those
    /// views are placed directly — PanelContainerView stays as the outer shell
    /// only when we are at the main view. For settings/stepLog we do NOT need
    /// the dim wrapper because sheets are only launched from SettingsView which
    /// is a full rootView swap — the hosting controller root is SettingsView
    /// itself at that point, so we wrap it too.
    func mainView() -> AnyView {
        let inner = PanelMainView(
            store: observable,
            onStepTap: { [weak self] job, step in
                guard let self else { return }
                self.savedNavState = .stepLog(job, step)
                self.navigate(to: self.wrapEnv(StepLogView(
                    job: job,
                    step: step,
                    onBack: { [weak self] in
                        self?.savedNavState = nil
                        self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                    }
                )))
            },
            onSelectSettings: { [weak self] in self?.navigateToSettings() }
        )
        // PanelContainerView applied once at root.
        return wrapEnv(PanelContainerView(content: inner))
    }

    /// Settings view. Also wrapped in PanelContainerView because sheets are
    /// launched from here and we need the dim overlay.
    func settingsView() -> AnyView {
        let inner = SettingsView(
            onBack: { [weak self] in
                self?.savedNavState = nil
                self?.panelSheetState.clearRunnerSheet()
                self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
            },
            store: observable
        )
        // PanelContainerView needed here too: sheets are presented from SettingsView.
        return wrapEnv(PanelContainerView(content: inner))
    }

    // MARK: - Navigation actions

    /// Navigates to the settings view and promotes to key for text input.
    func navigateToSettings() {
        savedNavState = .settings
        navigate(to: settingsView())
        makeKeyForTextInput()
    }

    // MARK: - NavState restoration

    /// Returns the correct view for a saved nav state, or nil if stale.
    func validatedView(for state: NavState) -> AnyView? {
        switch state {
        case .main:
            // Already at main — no navigation needed.
            return nil
        case .settings:
            return settingsView()
        case .stepLog(let job, let step):
            guard RunnerStore.shared.jobs.contains(where: { $0.id == job.id }) else { return nil }
            // No PanelContainerView here — StepLogView has no sheets.
            return wrapEnv(StepLogView(
                job: job,
                step: step,
                onBack: { [weak self] in
                    self?.savedNavState = nil
                    self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                }
            ))
        }
    }
}
