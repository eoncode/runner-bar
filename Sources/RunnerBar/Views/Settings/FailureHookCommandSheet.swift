// FailureHookCommandSheet.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - FailureHookCommandSheet
/// Sheet for configuring the shell command to run when a workflow fails.
struct FailureHookCommandSheet: View {
    let runner: RunnerModel
    @ObservedObject var store: RunnerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var command: String

    init(runner: RunnerModel, store: RunnerViewModel) {
        self.runner = runner
        self.store = store
        _command = State(initialValue: runner.failureHookCommand ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            sheetContent
        }
        .glassCard()
        .frame(width: 420)
    }

    // MARK: - Header
    private var sheetHeader: some View {
        HStack {
            Text("Failure Hook Command")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSection()
    }

    // MARK: - Content
    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shell command to execute when a workflow run fails for \u201c\(runner.runnerName)\u201d.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. /usr/local/bin/notify.sh", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private func save() {
        store.setFailureHook(command.isEmpty ? nil : command, for: runner)
        dismiss()
    }
}
// swiftlint:enable file_length type_body_length
