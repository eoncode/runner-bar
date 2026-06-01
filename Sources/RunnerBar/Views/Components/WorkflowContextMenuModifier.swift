// WorkflowContextMenuModifier.swift
// RunnerBar

import RunnerBarCore
import SwiftUI

// MARK: - Pasteboard helper
/// Copies `text` to the general pasteboard.
/// Compiler-enforced `@MainActor` — `NSPasteboard` requires main-thread access.
/// Callers on `MainActor` (e.g. button closures in `StepContextMenuModifier`) call
/// this directly. Callers in a `Task.detached` context use `await copyToPasteboard(_:)`
/// directly — the `@MainActor` annotation provides the actor hop; no `MainActor.run {}`
/// wrapper is needed.
@MainActor
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
/// `ViewModifier` that attaches a workflow-level right-click context menu to an `ActionRowView`.
private struct WorkflowContextMenuModifier: ViewModifier {
    /// The workflow action group this menu acts on.
    let group: WorkflowActionGroup

    /// Wraps `content` with a right-click context menu.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Context menu items for workflow-level actions.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = group.groupStatus == .completed
        let isLive      = group.groupStatus == .inProgress

        // Re-run failed
        // FIXME: #1077 Task.detached wraps a blocking call — migrating ghPost to async/await will unblock the cooperative thread pool
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun-failed-jobs") }
            }
        } label: {
            Label("Re-run Failed Jobs", systemImage: "arrow.counterclockwise")
        }
        .disabled(!isConcluded)

        // Re-run all
        // FIXME: #1077 Task.detached wraps a blocking call — migrating ghPost to async/await will unblock the cooperative thread pool
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
                runIDs.forEach { ghPost("repos/\(scope)/actions/runs/\($0)/rerun") }
            }
        } label: {
            Label("Re-run All Jobs", systemImage: "arrow.clockwise")
        }
        .disabled(!isConcluded)

        // Cancel
        // FIXME: #1077 Task.detached wraps a blocking call — migrating cancelRun to async/await will unblock the cooperative thread pool
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
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
            Task.detached(priority: .userInitiated) {
                guard let text = fetchActionLogs(group: g), !text.isEmpty else { return }
                await copyToPasteboard(text)
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
/// `ViewModifier` that attaches a job-level right-click context menu to a `JobRowCard`.
private struct JobContextMenuModifier: ViewModifier {
    /// The job this menu acts on.
    let job: ActiveJob
    /// The parent workflow action group, used for run-level cancel.
    let group: WorkflowActionGroup

    /// Wraps `content` with a right-click context menu.
    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    /// Context menu items for job-level actions.
    @ViewBuilder
    private var menuItems: some View {
        let isConcluded = job.conclusion != nil
        let isLive      = job.status == "in_progress"

        // Re-run job
        // FIXME: #1077 Task.detached wraps a blocking call — migrating ghPost to async/await will unblock the cooperative thread pool
        Button {
            let scope = group.repo
            let jobID = job.id
            Task.detached(priority: .userInitiated) {
                ghPost("repos/\(scope)/actions/jobs/\(jobID)/rerun")
            }
        } label: {
            Label("Re-run Job", systemImage: "arrow.counterclockwise")
        }
        .disabled(!isConcluded)

        // Cancel — ActiveJob has no runId; cancel all runs in the parent group
        // FIXME: #1077 Task.detached wraps a blocking call — migrating cancelRun to async/await will unblock the cooperative thread pool
        Button {
            let scope  = group.repo
            let runIDs = group.runs.map { $0.id }
            Task.detached(priority: .userInitiated) {
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
            Task.detached(priority: .userInitiated) {
                guard let text = fetchJobLog(jobID: j.id, scope: scope), !text.isEmpty else { return }
                await copyToPasteboard(text)
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
    /// Called when the user selects "View Log".
    let onTap: () -> Void

    /// Wraps `content` with a right-click context menu for step-level actions.
    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                copyToPasteboard(step.name)
            } label: {
                Label("Copy Step Name", systemImage: "doc.on.doc")
            }
            Button(action: onTap) {
                Label("View Log", systemImage: "text.alignleft")
            }
        }
    }
}
