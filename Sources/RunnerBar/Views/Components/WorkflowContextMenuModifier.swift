import AppKit
import SwiftUI

// MARK: - Pasteboard helper
/// Copies `text` to the general pasteboard on the main thread.
/// Extracted to avoid duplicated clipboard-write blocks across context menu modifiers.
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - WorkflowContextMenuModifier
// Adds a right-click context menu to an ActionRowView (workflow level).
// Actions mirror those in ActionDetailView's header bar:
//   re-run failed (concluded only)
//   re-run all (concluded only)
//   cancel (in_progress only)
//   copy log (always)
//   show workflow file on GitHub (always, opens first run's html_url)
//   show GitHub SHA (always, opens commit)
private struct WorkflowContextMenuModifier: ViewModifier {
    let group: ActionGroup

    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = group.groupStatus == .completed
        let isLive      = group.groupStatus == .inProgress

        // Re-run failed
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            DispatchQueue.global(qos: .userInitiated).async {
                runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun-failed-jobs") }
            }
        } label: {
            Label("Re-run Failed Jobs", systemImage: "arrow.counterclockwise")
        }
        .disabled(!isConcluded)

        // Re-run all
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            DispatchQueue.global(qos: .userInitiated).async {
                runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun") }
            }
        } label: {
            Label("Re-run All Jobs", systemImage: "arrow.clockwise")
        }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            DispatchQueue.global(qos: .userInitiated).async {
                runIDs.forEach { cancelRun(runID: $0, scope: scope) }
            }
        } label: {
            Label("Cancel", systemImage: "xmark.circle")
        }
        .disabled(!isLive)

        Divider()

        // Copy log
        Button {
            let g = group
            DispatchQueue.global(qos: .userInitiated).async {
                guard let text = fetchActionLogs(group: g), !text.isEmpty else { return }
                DispatchQueue.main.async { copyToPasteboard(text) }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show workflow file on GitHub
        Button {
            guard let htmlUrl = group.runs.first?.htmlUrl,
                  let runUrl  = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(runUrl)
        } label: {
            Label("Show Workflow on GitHub", systemImage: "doc.text")
        }
        .disabled(group.runs.first?.htmlUrl == nil)

        // Show GitHub SHA
        Button {
            let sha  = group.headSha
            let repo = group.repo
            guard let url = URL(string: "https://github.com/\(repo)/commit/\(sha)") else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label("Show Commit on GitHub", systemImage: "number")
        }
    }
}

// MARK: - JobContextMenuModifier
// Adds a right-click context menu to a JobRowCard (job level).
private struct JobContextMenuModifier: ViewModifier {
    let job: ActiveJob
    let group: ActionGroup

    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = job.conclusion != nil
        let isLive      = job.status == "in_progress"

        // Re-run failed jobs in the run (GitHub Actions API has no single-job rerun endpoint).
        Button {
            let scope = group.repo
            guard let run = group.runs.first else { return }
            let runID = run.id
            DispatchQueue.global(qos: .userInitiated).async {
                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
            }
        } label: {
            Label("Re-run Failed Jobs", systemImage: "arrow.clockwise")
        }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            DispatchQueue.global(qos: .userInitiated).async {
                runIDs.forEach { cancelRun(runID: $0, scope: scope) }
            }
        } label: {
            Label("Cancel", systemImage: "xmark.circle")
        }
        .disabled(!isLive)

        Divider()

        // Copy log
        Button {
            let jobID = job.id
            let scope = group.repo
            DispatchQueue.global(qos: .userInitiated).async {
                guard let text = fetchJobLog(jobID: jobID, scope: scope), !text.isEmpty else { return }
                DispatchQueue.main.async { copyToPasteboard(text) }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show on GitHub
        Button {
            guard let urlString = job.htmlUrl, let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label("Show on GitHub", systemImage: "safari")
        }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - StepContextMenuModifier
// Adds a right-click context menu to a StepRowView (step level). (#454 spec)
// Items per issue #454:
//   copy log  — fetches only this step's log via fetchStepLog(jobID:stepNumber:scope:)
//   show on github — opens job html_url (GitHub has no direct per-step URL)
//   show log in app — fires onTap closure (navigates to StepLogView)
// NOTE: JobStep.id IS the step sequence number (1-based) per ActionGroup.swift comment.
private struct StepContextMenuModifier: ViewModifier {
    let step: JobStep
    let job: ActiveJob
    /// Fires the same navigation as a row tap — opens StepLogView.
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        // Show log in app — same as tapping the row
        Button { onTap() } label: {
            Label("Show Log in App", systemImage: "doc.text.magnifyingglass")
        }

        Divider()

        // Copy log — only this step
        // JobStep.id is the 1-based step sequence number used by fetchStepLog.
        Button {
            let jobID   = job.id
            let stepNum = step.id  // fix: was step.number — JobStep uses .id as sequence number
            let scope: String = {
                if let urlStr = job.htmlUrl, let s = scopeFromHtmlUrl(urlStr) { return s }
                return ScopeStore.shared.scopes.first(where: { $0.contains("/") }) ?? ""
            }()
            DispatchQueue.global(qos: .userInitiated).async {
                guard let text = fetchStepLog(jobID: jobID, stepNumber: stepNum, scope: scope),
                      !text.isEmpty else { return }
                DispatchQueue.main.async { copyToPasteboard(text) }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show on GitHub — opens the job page (no direct per-step GitHub URL exists)
        Button {
            guard let urlString = job.htmlUrl, let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label("Show on GitHub", systemImage: "safari")
        }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - View extensions
extension View {
    /// Attaches the workflow-level context menu (right-click) to an action row.
    func workflowContextMenu(group: ActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }

    /// Attaches the job-level context menu (right-click) to a job row.
    func jobContextMenu(job: ActiveJob, group: ActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }

    /// Attaches the step-level context menu (right-click) to a step row. (#454)
    /// Requires the parent job and the onTap navigation closure so all 3 items are wired.
    func stepContextMenu(step: JobStep, job: ActiveJob, onTap: @escaping () -> Void) -> some View {
        modifier(StepContextMenuModifier(step: step, job: job, onTap: onTap))
    }
}
