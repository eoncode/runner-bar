// SettingsView.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - SettingsView
/// Root settings window rendered as a SwiftUI sheet or separate NSWindow.
struct SettingsView: View {
    @ObservedObject var store: RunnerViewModel
    let onDismiss: () -> Void

    @State private var selectedRunnerID: RunnerModel.ID?
    @State private var showAddRunner = false
    @State private var showAddScope = false
    @State private var runnerToDelete: RunnerModel?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedRunnerID,
               let runner = store.runners.first(where: { $0.id == id }) {
                RunnerDetailView(runner: runner, store: store)
            } else {
                placeholderDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 420)
        .sheet(isPresented: $showAddRunner) {
            AddRunnerSheet(store: store)
        }
        .sheet(isPresented: $showAddScope) {
            AddScopeSheet(store: store)
        }
        .confirmationDialog(
            "Delete runner?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let r = runnerToDelete {
                    store.removeRunner(r)
                    runnerToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { runnerToDelete = nil }
        } message: {
            if let r = runnerToDelete {
                Text("Remove \u201c\(r.runnerName)\u201d from RunnerBar?")
            }
        }
    }

    // MARK: - Sidebar
    private var sidebar: some View {
        List(selection: $selectedRunnerID) {
            sectionHeader("Runners")
            ForEach(store.runners) { runner in
                runnerRow(runner)
                    .tag(runner.id)
            }
            sectionHeader("Actions")
            addRunnersButton
            addScopeButton
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .help("Close Settings")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(RBFont.sectionCaption)
            .foregroundColor(.secondary)
    }

    private func runnerRow(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(runner.isOnline ? Color.rbSuccess : Color.rbTextTertiary)
                .frame(width: 7, height: 7)
            Text(runner.runnerName)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
        .contextMenu {
            Button(role: .destructive) {
                runnerToDelete = runner
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addRunnersButton: some View {
        Button(action: { showAddRunner = true }) {
            Label("Add Runner", systemImage: "plus")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }

    private var addScopeButton: some View {
        Button(action: { showAddScope = true }) {
            Label("Add Scope", systemImage: "plus.circle")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Placeholder
    private var placeholderDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Select a runner to view details")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
    }
}
// swiftlint:enable file_length type_body_length
