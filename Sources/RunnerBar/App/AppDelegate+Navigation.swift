// AppDelegate+Navigation.swift
// RunnerBar
import os
import RunnerBarCore
import SwiftUI

// MARK: - Navigation & view factories
//
// Extracted from AppDelegate.swift (#604).
// All view factory methods and the enrichment helper live here so AppDelegate.swift
// can focus on panel lifecycle, status item, and event monitor concerns.
//
// #1001: runnerDetailView(runner:) removed — runner editing is now a popover
// inside SettingsView (RunnerDetailPopover). NavState.runnerDetail also removed.
// #1001 Phase 6: onSelectRunner parameter removed from SettingsView.
// #992: scopeDetailView(entry:) removed — ScopeEditSheet is presented directly
// from SettingsView via @State selectedScopeEntry. NavState.scopeDetail removed.

// Shared ISO-8601 date formatter for this file.
// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
// keeping one file-level instance avoids repeated allocation on every step enrichment call.
// Safety: protected by iso8601Lock.

/// A Sendable wrapper for ISO8601DateFormatter.
private struct SendableFormatter: @unchecked Sendable {
    /// The internal formatter instance.
    let iso = ISO8601DateFormatter()
}
/// Lock for the formatter.
private let iso8601Lock = OSAllocatedUnfairLock(initialState: SendableFormatter())

/// Extension adding functionality to `AppDelegate`.
extension AppDelegate {

    // MARK: - Enrichment helper

    // ⚠️ BLOCKING I/O — this function performs synchronous network I/O via ghAPI().
    // ❌ NEVER call from the main thread.
    // ❌ NEVER call directly — always dispatch via DispatchQueue.global().
    // Marked nonisolated to opt out of @MainActor isolation.
    /// Performs the enrichStepsIfNeeded operation.
    nonisolated func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == .inProgress }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        return iso8601Lock.withLock { wrapper in
            makeActiveJob(from: fresh, iso: wrapper.iso, isDimmed: job.isDimmed)
        }
    }

    // MARK: - View factories

    /// Performs the mainView operation.
    func mainView() -> AnyView {
        savedNavState = nil
        return wrapEnv(PanelMainView(
            store: observable,
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
    func stepLogFromMain(job: ActiveJob, step: JobStep) -> AnyView {
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

    /// Performs the settingsView operation.
    func settingsView() -> AnyView {
        savedNavState = .settings
        // Skip makeKeyForTextInput during UI tests.
        // makeKeyAndOrderFront repositions the panel (AppKit recalculates frame
        // for the new key window), which invalidates the AX coordinate snapshot
        // XCTest has already taken — every subsequent click lands in the wrong place.
        // In UI tests we never type into text fields, so key status is not needed.
        // ❌ NEVER remove this guard — same pattern as the event monitor skip in openPanel().
        if ProcessInfo.processInfo.environment["UI_TESTING"] == nil {
            makeKeyForTextInput()
        }
        return wrapEnv(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            store: observable
        ))
    }

    /// Performs the validatedView operation.
    func validatedView(for state: NavState) -> AnyView? {
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
        }
    }
}
