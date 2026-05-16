import AppKit
import SwiftUI

// MARK: - AddRunnerSheet

/// Sheet for registering a new self-hosted runner.
struct AddRunnerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope = ""
    @State private var label = ""
    @State private var isRegistering = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Runner").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub Scope").font(.caption).foregroundColor(.secondary)
                TextField("owner/repo or org", text: $scope)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. self-hosted", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            if let msg = resultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(resultIsError ? .red : .green)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Register", action: register)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope.trimmingCharacters(in: .whitespaces).isEmpty || isRegistering)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func register() {
        isRegistering = true
        resultMessage = nil
        let trimmedScope = scope.trimmingCharacters(in: .whitespaces)
        Task.detached(priority: .userInitiated) {
            // RunnerLifecycleService manages already-installed runners via launchd only.
            // Remote registration requires a GitHub API token — open the GitHub setup page instead.
            let urlString: String
            if trimmedScope.contains("/") {
                urlString = "https://github.com/\(trimmedScope)/settings/actions/runners/new"
            } else {
                urlString = "https://github.com/organizations/\(trimmedScope)/settings/actions/runners/new"
            }
            await MainActor.run {
                isRegistering = false
                resultIsError = false
                resultMessage = "Opening GitHub runner setup..."
            }
            if let url = URL(string: urlString) {
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
        }
    }
}
