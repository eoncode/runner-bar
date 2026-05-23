// WorkflowContextMenuModifier.swift
// RunnerBar

import RunnerBarCore
import SwiftUI

// swiftlint:disable missing_docs

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
    let group: WorkflowActionGroup

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
    let group: WorkflowActionGroup

    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

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
    func workflowContextMenu(group: WorkflowActionGroup) -> some View {
        modifier(WorkflowContextMenuModifier(group: group))
    }

    func jobContextMenu(job: ActiveJob, group: WorkflowActionGroup) -> some View {
        modifier(JobContextMenuModifier(job: job, group: group))
    }

    func stepContextMenu(step: JobStep, job: ActiveJob, onTap: @escaping () -> Void) -> some View {
        modifier(StepContextMenuModifier(step: step, job: job, onTap: onTap))
    }
}

// MARK: - StepContextMenuModifier

private struct StepContextMenuModifier: ViewModifier {
    let step: JobStep
    let job: ActiveJob
    let onTap: () -> Void

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
// swiftlint:enable missing_docs
