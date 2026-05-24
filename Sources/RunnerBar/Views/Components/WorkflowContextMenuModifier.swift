// WorkflowContextMenuModifier.swift
// RunnerBar

import RunnerBarCore
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
/// `ViewModifier` that attaches a right-click context menu to an `ActionRowView`.
/// Provides workflow-level actions: re-run failed, re-run all, cancel, copy log, show on GitHub.
private struct WorkflowContextMenuModifier: ViewModifier {
    /// The workflow action group whose runs are targeted by the context menu actions.
    let group: WorkflowActionGroup

    /// Wraps `content` in a `.contextMenu` containing the workflow-level action items.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Builds the context menu item list for the workflow group.
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
/// `ViewModifier` that attaches a right-click context menu to a `JobRowCard`.
/// Provides job-level actions: re-run job, cancel, copy log, show on GitHub.
private struct JobContextMenuModifier: ViewModifier {
    /// The job whose actions are exposed by the context menu.
    let job: ActiveJob
    /// The parent workflow action group, used to cancel all in-progress runs when the job is live.
    let group: WorkflowActionGroup

    /// Wraps `content` in a `.contextMenu` containing the job-level action items.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Builds the context menu item list for the job.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = job.conclusion != nil
        let isLive      = job.status == "in_progress"

        // Re-run failed
        Button {
            let scope = group.repo
            let jobID = job.id
            DispatchQueue.global(qos: .userInitiated).async {
                ghPost("repos/\(scope)/actions/jobs/\(jobID)/rerun")
            }
        } label: {
            Label("Re-run Job", systemImage: "arrow.counterclockwise")
        }
        .disabled(!isConcluded)

        // Cancel — ActiveJob has no runId; cancel all runs in the parent group
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
            let j = job
            let scope = group.repo
            DispatchQueue.global(qos: .userInitiated).async {
                guard let text = fetchJobLog(jobID: j.id, scope: scope), !text.isEmpty else { return }
                DispatchQueue.main.async { copyToPasteboard(text) }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show job on GitHub
        Button {
            guard let htmlUrl = job.htmlUrl,
                  let url = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label("Show Job on GitHub", systemImage: "doc.text")
        }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - View extensions
extension View {
    /// Attaches a workflow-level right-click context menu to this view.
    func workflowContextMenu(group: WorkflowActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }

    /// Attaches a job-level right-click context menu to this view.
    func jobContextMenu(job: ActiveJob, group: WorkflowActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }

    /// Attaches a step-level right-click context menu to this view.
    func stepContextMenu(step: JobStep, job: ActiveJob, onTap: @escaping () -> Void) -> some View {
        modifier(StepContextMenuModifier(step: step, job: job, onTap: onTap))
    }
}

// MARK: - StepContextMenuModifier
/// `ViewModifier` that attaches a right-click context menu to a step row.
/// Provides step-level actions: copy step name, view log.
private struct StepContextMenuModifier: ViewModifier {
    /// The step whose name can be copied and whose log can be viewed.
    let step: JobStep
    // periphery:ignore
    /// The parent job; retained for future use (e.g. log fetching by job+step number).
    let job: ActiveJob
    /// Callback invoked when the user selects "View Log" from the context menu.
    let onTap: () -> Void

    /// Wraps `content` in a `.contextMenu` with copy-name and view-log actions.
    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(step.name, forType: .string)
            } label: {
                Label("Copy Step Name", systemImage: "doc.on.doc")
            }
            Button(action: onTap) {
                Label("View Log", systemImage: "text.alignleft")
            }
        }
    }
}
