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
// ❌ NEVER read panel.wantsKey — KeyablePanel is no longer used.
// ❌ makeKeyForTextInput() is now AppDelegate.makeKeyForTextInput() which calls
//   NSApp.activate(ignoringOtherApps: true).

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - View factories

    /// Wraps content in PanelContainerView for sheet-dim support, then wrapEnv.
    func mainView() -> AnyView {
        let content = PanelMainView(
            store: observable,
            onStepTap: { [weak self] job, step in
                guard let self else { return }
                self.savedNavState = .stepLog(jobId: job.id, stepIndex: step.number - 1)
                self.navigate(to: self.wrapEnv(StepLogView(
                    jobId: job.id,
                    initialStepIndex: step.number - 1,
                    onBack: { [weak self] in
                        self?.savedNavState = nil
                        self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                    }
                )))
            },
            onSelectSettings: { [weak self] in self?.navigateToSettings() }
        )
        return wrapEnv(PanelContainerView(content: content))
    }

    /// Builds the settings view wrapped in PanelContainerView.
    private func settingsView() -> AnyView {
        let content = SettingsView(
            onBack: { [weak self] in
                self?.savedNavState = nil
                self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
            },
            store: observable
        )
        return wrapEnv(PanelContainerView(content: content))
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
        case .settings:
            return settingsView()
        case .stepLog(let jobId, let stepIndex):
            guard RunnerStore.shared.jobs.contains(where: { $0.id == jobId }) else { return nil }
            return wrapEnv(StepLogView(
                jobId: jobId,
                initialStepIndex: stepIndex,
                onBack: { [weak self] in
                    self?.savedNavState = nil
                    self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                }
            ))
        }
    }
}
