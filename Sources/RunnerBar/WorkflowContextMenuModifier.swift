import AppKit
import SwiftUI

// MARK: - WorkflowContextMenuModifier
// Adds a right-click context menu to an ActionRowView (workflow level).
// Actions mirror those in ActionDetailView's header bar:
//   re-run failed  (concluded only)
//   re-run all     (concluded only)
//   cancel         (in_progress only)
//   copy log       (always)
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
                let text = fetchActionLogs(group: g)
                DispatchQueue.main.async {
                    guard let text, !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show workflow file on GitHub
        Button {
            guard let htmlUrl = group.runs.first?.htmlUrl,
                  let runUrl = URL(string: htmlUrl) else { return }
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

        // Re-run
        Button {
            let scope = group.repo
            let jobID = job.id
            guard let run = group.runs.first(where: { _ in true }) else { return }
            let runID = run.id
            DispatchQueue.global(qos: .userInitiated).async {
                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
                _ = jobID
            }
        } label: {
            Label("Re-run Job", systemImage: "arrow.clockwise")
        }
        .disabled(!isConcluded)

        // Cancel
        Button {
            let scope = group.repo
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
                let text = fetchJobLog(jobID: jobID, scope: scope)
                DispatchQueue.main.async {
                    guard let text, !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        } label: {
            Label("Copy Log", systemImage: "doc.on.doc")
        }

        Divider()

        // Show on GitHub
        Button {
            guard let urlString = job.htmlUrl,
                  let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label("Show on GitHub", systemImage: "safari")
        }
        .disabled(job.htmlUrl == nil)
    }
}

// MARK: - StepContextMenuModifier
// Adds a right-click context menu to a StepRowView (step level). (#455 Phase 2)
private struct StepContextMenuModifier: ViewModifier {
    let step: JobStep

    func body(content: Content) -> some View {
        content.contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            // Navigation is driven by the onTap closure on StepRowView.
            // This menu item is a visual affordance only.
        } label: {
            Label("View Step Log", systemImage: "doc.text.magnifyingglass")
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(step.name, forType: .string)
        } label: {
            Label("Copy Step Name", systemImage: "doc.on.doc")
        }
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

    /// Attaches the step-level context menu (right-click) to a step row. (#455)
    func stepContextMenu(step: JobStep) -> some View {
        modifier(StepContextMenuModifier(step: step))
    }
}
