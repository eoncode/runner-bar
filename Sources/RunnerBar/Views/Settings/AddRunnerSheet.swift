// AddRunnerSheet.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - AddRunnerSheet
/// Sheet for registering a new self-hosted runner with RunnerBar.
struct AddRunnerSheet: View {
    @ObservedObject var store: RunnerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var runnerName = ""
    @State private var scope = ""
    @State private var os = ""
    @State private var architecture = ""
    @State private var labels = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            sheetContent
        }
        .glassCard()
        .frame(width: 440)
    }

    // MARK: - Header
    private var sheetHeader: some View {
        HStack {
            Text("Add Runner")
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
            field("Runner name", text: $runnerName)
            field("Scope (owner/repo or org)", text: $scope)
            field("OS", text: $os)
            field("Architecture", text: $architecture)
            field("Labels (comma-separated)", text: $labels)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.rbDanger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Add") { submit() }
                    .keyboardShortcut(.return)
                    .disabled(runnerName.isEmpty || scope.isEmpty || isSubmitting)
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        let newRunner = RunnerModel(
            runnerName: runnerName,
            scope: scope,
            os: os.isEmpty ? nil : os,
            architecture: architecture.isEmpty ? nil : architecture,
            labels: labels.isEmpty ? [] : labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
        store.addRunner(newRunner)
        dismiss()
    }
}
// swiftlint:enable file_length type_body_length
