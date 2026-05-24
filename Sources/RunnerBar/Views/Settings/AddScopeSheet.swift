// AddScopeSheet.swift
// RunnerBar
// swiftlint:disable file_length type_body_length
import RunnerBarCore
import SwiftUI

// MARK: - AddScopeSheet
/// Sheet for adding a new GitHub scope (org or repo) to monitor.
struct AddScopeSheet: View {
    @ObservedObject var store: RunnerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var scopeInput = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            sheetContent
        }
        .glassCard()
        .frame(width: 380)
    }

    // MARK: - Header
    private var sheetHeader: some View {
        HStack {
            Text("Add Scope")
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
            Text("Enter an organisation name or owner/repo slug.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. myorg or myorg/myrepo", text: $scopeInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

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
                    .disabled(scopeInput.isEmpty || isSubmitting)
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        store.addScope(scopeInput.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
// swiftlint:enable file_length type_body_length
