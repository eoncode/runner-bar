// AppDelegate+Navigation.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - Navigation & view factories
//
// Extracted from AppDelegate.swift (#604).
// All view factory methods and the enrichment helper live here so AppDelegate.swift
// can focus on panel lifecycle, status item, and event monitor concerns.

/// Extension adding functionality to `AppDelegate`.
extension AppDelegate {

    // MARK: - Enrichment helper

    // ⚠️ BLOCKING I/O — this function performs synchronous network I/O via ghAPI().
    // ❌ NEVER call from the main thread.
    // ❌ NEVER call directly — always dispatch via DispatchQueue.global().
    // Marked nonisolated to opt out of @MainActor isolation.
    /// Performs the enrichStepsIfNeeded operation.
    nonisolated func enrichStepsIfNeeded(_ job: ActiveJob) -> ActiveJob {
        guard job.steps.isEmpty || job.steps.contains(where: { $0.status == "in_progress" }),
              let scope = scopeFromHtmlUrl(job.htmlUrl),
              let data = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: data)
        else { return job }
        let iso = ISO8601DateFormatter()
        return makeActiveJob(from: fresh, iso: iso, isDimmed: job.isDimmed)
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
    func runnerDetailView(runner: RunnerModel) -> AnyView {
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
    func scopeDetailView(entry: ScopeEntry) -> AnyView {
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
}
