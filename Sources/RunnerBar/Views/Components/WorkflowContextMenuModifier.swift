// WorkflowContextMenuModifier.swift
// RunnerBar

import RunnerBarCore
import SwiftUI

// MARK: - Pasteboard helper
/// Copies `text` to the general pasteboard.
/// `@MainActor` enforced -- `NSPasteboard` requires main-thread access.
@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - WorkflowContextMenuModifier
/// `ViewModifier` that attaches a workflow-level right-click context menu to an `ActionRowView`.
private struct WorkflowContextMenuModifier: ViewModifier {
    /// The workflow action group this menu acts on.
    let group: WorkflowActionGroup

    /// Wraps `content` with a right-click context menu containing workflow-level actions.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Context menu items: re-run failed, re-run all, cancel, copy log, open on GitHub.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = group.groupStatus == .completed
        let isLive      = group.groupStatus == .inProgress

        // Re-run failed
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { group in
                    for id in runIDs { group.addTask { await ghPost("repos/\(scope)/actions/runs/\(id)/rerun-failed-jobs") } }
                }
            }
        } label: { Label("Re-run Failed Jobs", systemImage: "arrow.counterclockwise") }
        .disabled(!isConcluded)

        // Re-run all
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { group in
                    for id in runIDs { group.addTask { await ghPost("repos/\(scope)/actions/runs/\(id)/rerun") } }
                }
            }
        } label: { Label("Re-run All Jobs", systemImage: "arrow.clockwise") }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { tg in
                    for id in runIDs { tg.addTask { await cancelRun(runID: id, scope: scope) } }
                }
            }
        } label: { Label("Cancel", systemImage: "xmark.circle") }
        .disabled(!isLive)
        Divider()
        Button {
            let g = group
            Task.detached(priority: .userInitiated) {
                guard let text = await fetchActionLogs(group: g), !text.isEmpty else { return }
                await copyToPasteboard(text)
            }
        } label: { Label("Copy Log", systemImage: "doc.on.doc") }
        Divider()
        Button {
            guard let htmlUrl = group.runs.first?.htmlUrl,
                  let runUrl  = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(runUrl)
        } label: { Label("Show Workflow on GitHub", systemImage: "doc.text") }
        .disabled(group.runs.first?.htmlUrl == nil)
        Button {
            let sha  = group.headSha
            let repo = group.repo
            guard let url = URL(string: "https://github.com/\(repo)/commit/\(sha)") else { return }
            NSWorkspace.shared.open(url)
        } label: { Label("Show Commit on GitHub", systemImage: "number") }
    }
}

// MARK: - JobContextMenuModifier
/// `ViewModifier` that attaches a job-level right-click context menu to a `JobRowCard`.
private struct JobContextMenuModifier: ViewModifier {
    /// The job this menu acts on.
    let job: ActiveJob
    /// The parent workflow action group, used for run-level re-run and cancel actions.
    let group: WorkflowActionGroup

    /// Wraps `content` with a right-click context menu containing job-level actions.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Context menu items: re-run job, cancel, copy log, open on GitHub.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = job.conclusion != nil
        let isLive      = job.status == "in_progress"

        // Re-run job
        Button {
            let scope = group.repo
            let jobID = job.id
            Task.detached(priority: .userInitiated) {
                await ghPost("repos/\(scope)/actions/jobs/\(jobID)/rerun")
            }
        } label: { Label("Re-run Job", systemImage: "arrow.counterclockwise") }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { tg in
                    for id in runIDs { tg.addTask { await cancelRun(runID: id, scope: scope) } }
                }
            }
        } label: { Label("Cancel", systemImage: "xmark.circle") }
        .disabled(!isLive)
        Divider()
        Button {
            let j = job
            let scope = group.repo
            Task.detached(priority: .userInitiated) {
                guard let text = await fetchJobLog(jobID: j.id, scope: scope), !text.isEmpty else { return }
                await copyToPasteboard(text)
            }
        } label: { Label("Copy Log", systemImage: "doc.on.doc") }
        Divider()
        Button {
            guard let htmlUrl = job.htmlUrl, let url = URL(string: htmlUrl) else { return }
            NSWorkspace.shared.open(url)
        } label: { Label("Show Job on GitHub", systemImage: "doc.text") }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - View extensions
/// Convenience modifiers for attaching workflow, job, and step context menus to any `View`.
extension View {
    /// Attaches a workflow-level right-click context menu (re-run, cancel, copy log, open on GitHub).
    func workflowContextMenu(group: WorkflowActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }

    /// Attaches a job-level right-click context menu (re-run, cancel, copy log, open on GitHub).
    func jobContextMenu(job: ActiveJob, group: WorkflowActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }

    /// Attaches a step-level right-click context menu (copy step name, view log).
    func stepContextMenu(step: JobStep, onTap: @escaping () -> Void) -> some View {
        modifier(StepContextMenuModifier(step: step, onTap: onTap))
    }
}

// MARK: - StepContextMenuModifier
/// `ViewModifier` that attaches a step-level right-click context menu to a step row.
private struct StepContextMenuModifier: ViewModifier {
    /// The step this menu acts on.
    let step: JobStep
    /// Called when the user selects "View Log" from the context menu.
    let onTap: () -> Void

    /// Wraps `content` with step-level context menu actions (copy name, view log).
    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                copyToPasteboard(step.name)
            } label: { Label("Copy Step Name", systemImage: "doc.on.doc") }
            Button(action: onTap) {
                Label("View Log", systemImage: "text.alignleft")
            }
        }
    }
}
